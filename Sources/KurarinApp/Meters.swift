import Combine
import Foundation

/// The level meters, kept apart from everything else the interface reads.
///
/// These change thirty times a second by their nature, and in SwiftUI a change
/// to an observable object invalidates every view watching it — so publishing
/// them alongside the device lists and the parameters had the whole settings
/// form re-laid-out at meter rate. A sampled profile of the app under load was
/// 1404 frames of SwiftUI layout against three of everything this project
/// actually does; it was the largest cost in the program by a wide margin, and
/// enough on its own to trip the CPU limit macOS applies to background apps.
///
/// Splitting them into their own object means a moving bar redraws the bar.
@MainActor
final class Meters: ObservableObject {
    @Published private(set) var input: Float = 0
    @Published private(set) var output: Float = 0
    /// Hangs behind the input bar so a peak can be read after it has passed.
    @Published private(set) var inputPeak: Float = 0

    /// The numbers beside the bars, republished a few times a second rather
    /// than thirty.
    ///
    /// Changing a string is what makes SwiftUI measure text again, and text
    /// measurement is the expensive half of a layout pass. A decibel readout
    /// that changes at reading speed is also easier to read than one that
    /// flickers.
    @Published private(set) var inputDecibels: Float = -.infinity
    @Published private(set) var outputDecibels: Float = -.infinity

    private var ticksSinceReadout = 0
    private static let readoutEvery = 6

    /// Jump to a new peak, fall back gently. An instantaneous meter flickers
    /// too fast to read; one that only rises never comes down.
    private static let fall: Float = 0.85
    private static let peakFall: Float = 0.97

    /// Below this the difference is under a pixel on any meter anyone will
    /// draw, and publishing it only asks SwiftUI to do the same work again.
    private static let visibleChange: Float = 0.002

    func update(input newInput: Float, output newOutput: Float) {
        let nextInput = max(newInput, input * Meters.fall)
        let nextOutput = max(newOutput, output * Meters.fall)
        let nextPeak = max(newInput, inputPeak * Meters.peakFall)

        if abs(nextInput - input) > Meters.visibleChange { input = nextInput }
        if abs(nextOutput - output) > Meters.visibleChange { output = nextOutput }
        if abs(nextPeak - inputPeak) > Meters.visibleChange { inputPeak = nextPeak }

        ticksSinceReadout += 1
        if ticksSinceReadout >= Meters.readoutEvery {
            ticksSinceReadout = 0
            let asDecibels: (Float) -> Float = { $0 > 0 ? 20 * log10($0) : -.infinity }
            let nextInputDB = asDecibels(nextInput)
            let nextOutputDB = asDecibels(nextOutput)
            // Rounded before comparing, because the readout shows whole
            // decibels and a change under one of them is not a change.
            if nextInputDB.rounded() != inputDecibels.rounded() { inputDecibels = nextInputDB }
            if nextOutputDB.rounded() != outputDecibels.rounded() { outputDecibels = nextOutputDB }
        }
    }

    func clear() {
        if input != 0 { input = 0 }
        if output != 0 { output = 0 }
        if inputPeak != 0 { inputPeak = 0 }
        if inputDecibels.isFinite { inputDecibels = -.infinity }
        if outputDecibels.isFinite { outputDecibels = -.infinity }
        ticksSinceReadout = 0
    }
}
