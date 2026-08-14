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

    public static func load(_ url: URL, sampleRate: Double) throws -> [Float] {
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
        ) else {
            throw SampleLoaderError.unreadable(url)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SampleLoaderError.unreadable(url)
        }

        let sourceCapacity: AVAudioFrameCount = 16384
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity) else {
            throw SampleLoaderError.unreadable(url)
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(sourceCapacity) * ratio) + 1024
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw SampleLoaderError.unreadable(url)
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        var reachedEnd = false

        while !reachedEnd {
            targetBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                do {
                    try file.read(into: sourceBuffer, frameCount: sourceCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if sourceBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if conversionError != nil { throw SampleLoaderError.unreadable(url) }

            if let channel = targetBuffer.floatChannelData?[0], targetBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(targetBuffer.frameLength)))
            }

            if status == .endOfStream || status == .error { reachedEnd = true }
        }

        guard !samples.isEmpty else { throw SampleLoaderError.empty(url) }
        return samples
    }
}
