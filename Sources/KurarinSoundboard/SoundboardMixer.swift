import Foundation

/// Plays loaded samples into the render callback.
///
/// The mixer owns raw sample buffers rather than Swift arrays because the audio
/// thread reads them while the UI thread may be installing a replacement, and a
/// Swift array can move when it is reassigned. Buffers are handed over through
/// the command queue, and the buffer they displace is handed back through a
/// second queue so the UI thread frees it only once the audio thread has
/// finished with it. Freeing it directly would risk pulling memory out from
/// under a callback mid-read.
public final class SoundboardMixer {
    public static let slotCount = 12
    private static let maximumVoices = 8

    enum Command {
        case install(slot: Int, samples: UnsafeMutablePointer<Float>, count: Int)
        case clear(slot: Int)
        case play(slot: Int, gain: Float, loops: Bool)
        case stop(slot: Int)
        case stopAll
        case setGain(slot: Int, gain: Float)
    }

    struct Retired {
        let pointer: UnsafeMutablePointer<Float>
        let count: Int
    }

    private struct Bank {
        var samples: UnsafeMutablePointer<Float>?
        var count: Int = 0
        var gain: Float = 1
    }

    private struct Voice {
        var slot: Int = -1
        var position: Int = 0
        var loops: Bool = false
        var active: Bool { slot >= 0 }
    }

    private let commands = CommandQueue<Command>(capacity: 256)
    private let retired = CommandQueue<Retired>(capacity: 64)

    private var banks: [Bank]
    private var voices: [Voice]

    public init() {
        banks = [Bank](repeating: Bank(), count: SoundboardMixer.slotCount)
        voices = [Voice](repeating: Voice(), count: SoundboardMixer.maximumVoices)
    }

    deinit {
        collectRetiredBuffers()
        for bank in banks {
            if let pointer = bank.samples {
                pointer.deallocate()
            }
        }
    }

    // MARK: - Control side

    /// Copies the samples into a buffer the audio thread can own.
    ///
    /// False means the handover queue was full and the sample was not installed
    /// — worth surfacing, because the slot would otherwise look loaded and play
    /// nothing.
    @discardableResult
    public func install(_ samples: [Float], at slot: Int) -> Bool {
        guard banks.indices.contains(slot), !samples.isEmpty else { return false }

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.update(from: base, count: samples.count)
        }

        let accepted = commands.push(.install(slot: slot, samples: buffer, count: samples.count))
        if !accepted {
            buffer.deallocate()
        }
        collectRetiredBuffers()
        return accepted
    }

    public func clear(slot: Int) {
        commands.push(.clear(slot: slot))
        collectRetiredBuffers()
    }

    public func play(slot: Int, gain: Float = 1, loops: Bool = false) {
        commands.push(.play(slot: slot, gain: gain, loops: loops))
    }

    public func stop(slot: Int) {
        commands.push(.stop(slot: slot))
    }

    public func stopAll() {
        commands.push(.stopAll)
    }

    public func setGain(_ gain: Float, at slot: Int) {
        commands.push(.setGain(slot: slot, gain: gain))
    }

    /// Frees buffers the audio thread has released. Safe to call at any time
    /// from the control thread; the audio thread never touches these again.
    public func collectRetiredBuffers() {
        retired.drain { $0.pointer.deallocate() }
    }

    // MARK: - Audio side

    /// Mixes all active voices additively into `buffer`.
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        applyPendingCommands()

        for voiceIndex in voices.indices where voices[voiceIndex].active {
            var voice = voices[voiceIndex]
            let bank = banks[voice.slot]
            guard let samples = bank.samples, bank.count > 0 else {
                voices[voiceIndex].slot = -1
                continue
            }

            var frame = 0
            while frame < frameCount {
                if voice.position >= bank.count {
                    if voice.loops {
                        voice.position = 0
                    } else {
                        voice.slot = -1
                        break
                    }
                }
                let available = min(frameCount - frame, bank.count - voice.position)
                for i in 0..<available {
                    buffer[frame + i] += samples[voice.position + i] * bank.gain
                }
                voice.position += available
                frame += available
            }

            voices[voiceIndex] = voice
        }
    }

    public var hasActiveVoices: Bool {
        voices.contains { $0.active }
    }

    private func applyPendingCommands() {
        commands.drain { command in
            switch command {
            case .install(let slot, let samples, let count):
                guard banks.indices.contains(slot) else {
                    retired.push(Retired(pointer: samples, count: count))
                    return
                }
                stopVoices(on: slot)
                if let previous = banks[slot].samples {
                    retired.push(Retired(pointer: previous, count: banks[slot].count))
                }
                banks[slot].samples = samples
                banks[slot].count = count

            case .clear(let slot):
                guard banks.indices.contains(slot) else { return }
                stopVoices(on: slot)
                if let previous = banks[slot].samples {
                    retired.push(Retired(pointer: previous, count: banks[slot].count))
                }
                banks[slot].samples = nil
                banks[slot].count = 0

            case .play(let slot, let gain, let loops):
                guard banks.indices.contains(slot), banks[slot].samples != nil else { return }
                banks[slot].gain = gain
                start(slot: slot, loops: loops)

            case .stop(let slot):
                stopVoices(on: slot)

            case .stopAll:
                for index in voices.indices { voices[index].slot = -1 }

            case .setGain(let slot, let gain):
                guard banks.indices.contains(slot) else { return }
                banks[slot].gain = gain
            }
        }
    }

    private func start(slot: Int, loops: Bool) {
        // Retriggering a slot restarts it rather than layering a second copy;
        // repeated taps on a meme button should not pile up into a wall.
        if let existing = voices.firstIndex(where: { $0.slot == slot }) {
            voices[existing].position = 0
            voices[existing].loops = loops
            return
        }
        // Steal the furthest-advanced voice when all are busy.
        let free = voices.firstIndex { !$0.active }
        let index = free ?? voices.indices.max(by: { voices[$0].position < voices[$1].position })!
        voices[index] = Voice(slot: slot, position: 0, loops: loops)
    }

    private func stopVoices(on slot: Int) {
        for index in voices.indices where voices[index].slot == slot {
            voices[index].slot = -1
        }
    }
}
