import KurarinAllocProbe
import XCTest
@testable import KurarinDSP

/// The project's hardest rule, checked rather than assumed.
///
/// `malloc` takes a lock. A render callback that blocks on it misses its
/// deadline and the user hears a gap, so nothing on the audio thread may
/// allocate — no array growth, no boxing, no Objective-C. Every unit here has
/// been written to that rule and reviewed against it by eye, which has already
/// missed one violation: the hum detector built a temporary array once a
/// second to find its loudest bin.
final class AllocationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if DEBUG
        throw XCTSkip("""
            Only meaningful in a release build. Without the optimiser Swift \
            allocates and frees a block per loop iteration for bookkeeping it \
            otherwise removes, so every unit here would look like it allocates \
            once per sample. Run: swift test -c release
            """)
        #endif
        XCTAssertEqual(
            kurarin_alloc_probe_is_working(), 1,
            "the allocation probe sees nothing, so every test in this file would pass vacuously"
        )
    }

    /// Runs `body` twice: once to let any first-call setup happen, then again
    /// under the counter. Steady state is what the audio thread lives in.
    private func allocations(during body: () -> Void) -> UInt64 {
        body()
        kurarin_alloc_probe_begin()
        body()
        return kurarin_alloc_probe_end()
    }

    private func drive(_ unit: AudioProcessor, _ signal: [Float], blockSize: Int = 256) -> UInt64 {
        var buffer = signal
        return allocations {
            buffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                var offset = 0
                while offset < pointer.count {
                    let frames = min(blockSize, pointer.count - offset)
                    unit.process(base + offset, frameCount: frames)
                    offset += frames
                }
            }
        }
    }

    private var speech: [Float] {
        var signal = Signal.sine(frequency: 140, frames: 48000, amplitude: 0.4)
        let noise = Signal.noise(frames: 48000, amplitude: 0.05)
        for i in signal.indices { signal[i] += noise[i] }
        return signal
    }

    func testTheProbeCatchesAnAllocationInThisHarness() {
        var sink: [Float] = []
        let seen = allocations { sink = [Float](repeating: 0, count: 8192) }
        XCTAssertGreaterThan(seen, 0, "the harness itself must be able to see an allocation")
        XCTAssertEqual(sink.count, 8192)
    }

    func testWholeChainAllocatesNothing() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate)
        var parameters = VoiceParameters()
        parameters.pitchRatio = 1.35
        parameters.formantRatio = 1.18
        parameters.noiseReduction = 0.6
        parameters.clickSuppression = 0.7
        parameters.humRemoval = 0.5
        parameters.breathiness = 0.4
        parameters.highBandResynthesis = 0.5
        parameters.gateEnabled = true
        chain.apply(parameters)

        XCTAssertEqual(drive(chain, speech), 0)
    }

    /// Bypassed is a different code path through every unit, and one that runs
    /// whenever a control sits at zero.
    func testWholeChainAllocatesNothingWhileBypassed() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate)
        chain.apply(VoiceParameters())
        XCTAssertEqual(drive(chain, speech), 0)
    }

    func testUnitsAllocateNothing() {
        let suppressor = TransientSuppressor(sampleRate: Signal.sampleRate)
        suppressor.strength = 0.8
        suppressor.isVoiced = true
        XCTAssertEqual(drive(suppressor, speech), 0, "transient suppressor")

        let reducer = NoiseReducer(sampleRate: Signal.sampleRate)
        reducer.strength = 0.7
        XCTAssertEqual(drive(reducer, speech), 0, "noise reducer")

        let hum = HumRemover(sampleRate: Signal.sampleRate)
        hum.strength = 0.8
        XCTAssertEqual(drive(hum, speech), 0, "hum remover")

        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.4
        shifter.formantRatio = 1.2
        XCTAssertEqual(drive(shifter, speech), 0, "voice shifter")

        let shaper = HighBandShaper(sampleRate: Signal.sampleRate, delayFrames: 512)
        shaper.mix = 0.6
        shaper.isVoiced = true
        XCTAssertEqual(drive(shaper, speech), 0, "high band shaper")

        let breath = BreathGenerator(sampleRate: Signal.sampleRate)
        breath.amount = 0.5
        breath.isVoiced = true
        XCTAssertEqual(drive(breath, speech), 0, "breath generator")

        let limiter = Limiter(sampleRate: Signal.sampleRate)
        XCTAssertEqual(drive(limiter, speech), 0, "limiter")

        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.enabled = true
        XCTAssertEqual(drive(gate, speech), 0, "noise gate")

        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 0.4
        XCTAssertEqual(drive(reverb, speech), 0, "reverb")
    }

    /// The tracker is fed and analysed from the callback too, on its own hop
    /// rather than per block.
    func testPitchTrackerAllocatesNothing() {
        let tracker = PitchTracker(sampleRate: Signal.sampleRate, minimumHz: 75)
        var buffer = speech
        let seen = allocations {
            buffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                var offset = 0
                while offset < pointer.count {
                    let frames = min(256, pointer.count - offset)
                    tracker.push(base + offset, frameCount: frames)
                    tracker.analyse()
                    offset += frames
                }
            }
        }
        XCTAssertEqual(seen, 0)
    }

    /// A block longer than the chain's scratch buffers takes the chunking path.
    func testOversizedBlockAllocatesNothing() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate)
        var parameters = VoiceParameters()
        parameters.pitchRatio = 1.3
        chain.apply(parameters)
        XCTAssertEqual(drive(chain, speech, blockSize: 9000), 0)
    }
}
