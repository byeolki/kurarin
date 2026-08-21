import Foundation
// AVFoundation's buffer types predate strict concurrency. The conversion
// closure below runs synchronously on this thread, so the capture is safe.
@preconcurrency import AVFoundation

public struct SoundboardSlot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var fileURL: URL
    public var volume: Float
    public var loops: Bool

    public init(id: UUID = UUID(), name: String, fileURL: URL, volume: Float = 1, loops: Bool = false) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.volume = volume
        self.loops = loops
    }
}

public enum SampleLoaderError: Error, LocalizedError {
    case unreadable(URL)
    case empty(URL)
    case tooLong(URL, seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read \(url.lastPathComponent)."
        case .empty(let url):
            return "\(url.lastPathComponent) contains no audio."
        case .tooLong(let url, let seconds):
            return "\(url.lastPathComponent) is \(Int(seconds))s long; the limit is \(Int(SampleLoader.maximumSeconds))s."
        }
    }
}

/// Decodes files into the exact format the mixer plays.
///
/// All the conversion happens here rather than during playback: the audio
/// thread must not touch a decoder, allocate, or hit the disk, so a sample
/// arrives already mono, already at the engine's sample rate, already in
/// memory. Anything that can fail about a file fails at load time, where there
/// is a user to tell.
public enum SampleLoader {
    public static let maximumSeconds: Double = 120

    /// How much of the file is handed to the converter at a time. Only a
    /// working-set size — the whole decoded sample ends up in memory either
    /// way.
    private static let sourceCapacity: AVAudioFrameCount = 16384

    public static func load(_ url: URL, sampleRate: Double) throws -> [Float] {
        let conversion = try prepare(url, sampleRate: sampleRate)
        let samples = try drain(conversion, from: url)
        guard !samples.isEmpty else { throw SampleLoaderError.empty(url) }
        return samples
    }

    /// Everything needed to pump one file through the converter, all of it
    /// established before a single sample is read.
    private struct Conversion {
        let file: AVAudioFile
        let converter: AVAudioConverter
        let source: AVAudioPCMBuffer
        let target: AVAudioPCMBuffer
        /// Output frames per input frame, used to size the destination.
        let ratio: Double
    }

    /// Opens the file and builds the converter, rejecting anything the mixer
    /// could not play.
    ///
    /// Every failure here is `.unreadable` bar the two the user can act on:
    /// an empty file and one over the length limit. AVFoundation's own errors
    /// name internal formats rather than anything worth showing.
    private static func prepare(_ url: URL, sampleRate: Double) throws -> Conversion {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw SampleLoaderError.unreadable(url)
        }

        let sourceFormat = file.processingFormat
        let duration = Double(file.length) / sourceFormat.sampleRate
        guard file.length > 0 else { throw SampleLoaderError.empty(url) }
        guard duration <= maximumSeconds else {
            throw SampleLoaderError.tooLong(url, seconds: duration)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SampleLoaderError.unreadable(url)
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        // Headroom on top of the ratio: a resampler emits its filter's priming
        // frames on the first call, so the exact ratio is a floor rather than
        // a bound.
        let targetCapacity = AVAudioFrameCount(Double(sourceCapacity) * ratio) + 1024

        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity),
              let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw SampleLoaderError.unreadable(url)
        }

        return Conversion(file: file, converter: converter, source: source, target: target, ratio: ratio)
    }

    /// Runs the converter until the file is exhausted, collecting the output.
    private static func drain(_ conversion: Conversion, from url: URL) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(conversion.file.length) * conversion.ratio) + 1024)

        while true {
            conversion.target.frameLength = 0
            var conversionError: NSError?
            let status = conversion.converter.convert(
                to: conversion.target,
                error: &conversionError
            ) { _, outStatus in
                supply(conversion, outStatus)
            }

            if conversionError != nil { throw SampleLoaderError.unreadable(url) }

            if let channel = conversion.target.floatChannelData?[0], conversion.target.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(conversion.target.frameLength))
                )
            }

            if status == .endOfStream || status == .error { return samples }
        }
    }

    /// Reads the next block for the converter to consume.
    ///
    /// A read that throws is treated as the end rather than an error: a
    /// truncated file should play what it has, and anything genuinely broken
    /// has already failed in `prepare`.
    private static func supply(
        _ conversion: Conversion,
        _ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        do {
            try conversion.file.read(into: conversion.source, frameCount: sourceCapacity)
        } catch {
            outStatus.pointee = .endOfStream
            return nil
        }
        guard conversion.source.frameLength > 0 else {
            outStatus.pointee = .endOfStream
            return nil
        }
        outStatus.pointee = .haveData
        return conversion.source
    }
}
