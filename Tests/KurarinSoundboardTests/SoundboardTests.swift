import XCTest
@testable import KurarinSoundboard

final class CommandQueueTests: XCTestCase {
    func testPreservesOrder() {
        let queue = CommandQueue<Int>(capacity: 16)
        for value in 0..<10 { XCTAssertTrue(queue.push(value)) }

        var received: [Int] = []
        queue.drain { received.append($0) }
        XCTAssertEqual(received, Array(0..<10))
    }

    func testRejectsPushWhenFull() {
        let queue = CommandQueue<Int>(capacity: 4)
        // One slot is always kept empty to tell full from empty.
        XCTAssertTrue(queue.push(1))
        XCTAssertTrue(queue.push(2))
        XCTAssertTrue(queue.push(3))
        XCTAssertFalse(queue.push(4))
    }

    func testWrapsAround() {
        let queue = CommandQueue<Int>(capacity: 4)
        for round in 0..<20 {
            XCTAssertTrue(queue.push(round))
            XCTAssertEqual(queue.pop(), round)
        }
        XCTAssertNil(queue.pop())
    }

    func testSurvivesConcurrentProducerAndConsumer() {
        let queue = CommandQueue<Int>(capacity: 64)
        let total = 20000
        let done = expectation(description: "producer finished")

        var received: [Int] = []
        received.reserveCapacity(total)

        DispatchQueue.global().async {
            var sent = 0
            while sent < total {
                if queue.push(sent) { sent += 1 }
            }
            done.fulfill()
        }

        while received.count < total {
            if let value = queue.pop() { received.append(value) }
        }

        wait(for: [done], timeout: 20)
        XCTAssertEqual(received, Array(0..<total))
    }
}

final class SoundboardMixerTests: XCTestCase {
    private func render(_ mixer: SoundboardMixer, frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            mixer.render(into: base, frameCount: buffer.count)
        }
        return output
    }

    func testSilentUntilPlayed() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 1, count: 100), at: 0)
        XCTAssertEqual(render(mixer, frames: 64).max(), 0)
    }

    func testPlaysInstalledSample() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.5, count: 100), at: 0)
        mixer.play(slot: 0)

        let output = render(mixer, frames: 64)
        XCTAssertEqual(output[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(output[63], 0.5, accuracy: 1e-6)
    }

    func testStopsAtEndOfSample() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.5, count: 32), at: 0)
        mixer.play(slot: 0)

        let output = render(mixer, frames: 64)
        XCTAssertEqual(output[31], 0.5, accuracy: 1e-6)
        XCTAssertEqual(output[32], 0, accuracy: 1e-6)
        XCTAssertFalse(mixer.hasActiveVoices)
    }

    func testLoopingWrapsAround() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.25, count: 16), at: 0)
        mixer.play(slot: 0, loops: true)

        let output = render(mixer, frames: 64)
        XCTAssertTrue(output.allSatisfy { abs($0 - 0.25) < 1e-6 })
        XCTAssertTrue(mixer.hasActiveVoices)
    }

    func testRetriggerRestartsInsteadOfLayering() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.4, count: 1000), at: 0)
        mixer.play(slot: 0)
        _ = render(mixer, frames: 64)

        mixer.play(slot: 0)
        let output = render(mixer, frames: 64)
        // Layering would double the amplitude.
        XCTAssertEqual(output[0], 0.4, accuracy: 1e-6)
    }

    func testMixesSlotsAdditively() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.3, count: 100), at: 0)
        mixer.install([Float](repeating: 0.2, count: 100), at: 1)
        mixer.play(slot: 0)
        mixer.play(slot: 1)

        XCTAssertEqual(render(mixer, frames: 32)[0], 0.5, accuracy: 1e-6)
    }

    func testGainScalesOutput() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 1, count: 100), at: 0)
        mixer.play(slot: 0, gain: 0.25)
        XCTAssertEqual(render(mixer, frames: 32)[0], 0.25, accuracy: 1e-6)
    }

    func testStopAllSilencesEverything() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.5, count: 1000), at: 0)
        mixer.install([Float](repeating: 0.5, count: 1000), at: 1)
        mixer.play(slot: 0)
        mixer.play(slot: 1)
        _ = render(mixer, frames: 32)

        mixer.stopAll()
        XCTAssertEqual(render(mixer, frames: 32).max(), 0)
    }

    func testReinstallingWhilePlayingDoesNotCrash() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 0.5, count: 4800), at: 0)
        mixer.play(slot: 0, loops: true)

        for round in 0..<40 {
            _ = render(mixer, frames: 256)
            mixer.install([Float](repeating: Float(round % 4) * 0.1, count: 2400), at: 0)
            mixer.collectRetiredBuffers()
        }
        XCTAssertTrue(Signalish.isFinite(render(mixer, frames: 256)))
    }

    func testIgnoresOutOfRangeSlots() {
        let mixer = SoundboardMixer()
        mixer.install([Float](repeating: 1, count: 10), at: 999)
        mixer.play(slot: 999)
        XCTAssertEqual(render(mixer, frames: 32).max(), 0)
    }
}

enum Signalish {
    static func isFinite(_ samples: [Float]) -> Bool {
        samples.allSatisfy { $0.isFinite }
    }
}
