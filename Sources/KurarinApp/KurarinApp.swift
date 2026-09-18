import AppKit
import SwiftUI

/// Owns everything that outlives a window.
///
/// The menu bar item is AppKit, so the app's model and its one window are held
/// here rather than in a SwiftUI scene: a `MenuBarExtra` cannot tell a left
/// click from a right one, and telling them apart is the point.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(model: model)
    }

    /// Closing the window does not quit an app that lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A recording abandoned mid-file is unplayable: the index a QuickTime
    /// file needs is written when the recording is finished, not as it goes.
    /// Quitting is a normal way to stop, so it waits — briefly, and bounded,
    /// because a quit that appears to hang is worse than a lost recording.
    func applicationWillTerminate(_ notification: Notification) {
        model.finishRecordingForQuit()
        model.stop()
    }
}

@main
struct KurarinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// No scene of its own. The window is an `NSWindow` the status item makes
    /// when it is first asked for, so SwiftUI needs only something to satisfy
    /// the protocol — and an empty Settings scene is the one that adds no menu
    /// item, no window and no Dock behaviour.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Main window

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            DevicesTab().tabItem { Label("Devices", systemImage: "waveform") }
            VoiceTab().tabItem { Label("Voice", systemImage: "person.wave.2") }
            SoundboardTab().tabItem { Label("Soundboard", systemImage: "square.grid.3x3") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding()
        .safeAreaInset(edge: .bottom) { StatusBar() }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button(model.isRunning ? "Stop" : "Start") { model.toggleRunning() }
                .keyboardShortcut(.return)

            // Watching `meters` rather than the model: a bar that moves
            // thirty times a second must not invalidate the window with it.
            MeterPair(meters: model.meters)

            Spacer()

            if let message = model.statusMessage {
                Label(
                    message,
                    systemImage: model.statusIsWarning ? "exclamationmark.triangle" : "checkmark.circle"
                )
                    .foregroundStyle(model.statusIsWarning ? .orange : .secondary)
                    .lineLimit(2)
                    .font(.caption)
            } else if model.isRunning {
                Text("Latency \(model.latencyDescription)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

/// A level meter on a decibel scale.
///
/// Hearing is logarithmic and so are microphones. A voice at a perfectly
/// healthy -12 dBFS is an amplitude of 0.25, which on a linear bar looks like
/// almost nothing, and a quiet-but-usable -30 dB — where a USB microphone with
/// its gain knob down sits — is 3% of the width and reads as "broken". The
/// scale runs from -60 dB, below which nothing is worth showing, to 0.
/// The two bars in the status bar, kept in their own view so that only they
/// are rebuilt when a level changes.
struct MeterPair: View {
    @ObservedObject var meters: Meters

    var body: some View {
        Group {
            LevelMeter(label: "In", level: meters.input, decibels: meters.inputDecibels)
            LevelMeter(label: "Out", level: meters.output, decibels: meters.outputDecibels)
        }
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float
    let decibels: Float

    /// A marker that hangs behind the bar, so a peak can be read after it has
    /// passed. Optional: only the input meter is something the user is aiming.
    var peak: Float?
    /// Shades the range a speaking voice should be landing in, which turns
    /// "how loud should this be" into "put the bar in the green".
    var showsTarget = false
    var width: CGFloat = 70

    private static let floorDB: Float = -60

    private static func position(ofDB db: Float) -> Double {
        Double(min(max((db - floorDB) / -floorDB, 0), 1))
    }

    private static func position(ofLevel level: Float) -> Double {
        level > 0 ? position(ofDB: 20 * log10(level)) : 0
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)

            // Drawn rather than built out of views. A stack of shapes is laid
            // out every time it changes, and a meter changes twenty times a
            // second — which had AppKit walking the whole window's view tree
            // at that rate and cost more than every other part of this program
            // put together. A canvas of a fixed size only repaints.
            Canvas { context, size in
                let full = size.width
                let radius = size.height / 2
                func capsule(from x: Double, to end: Double) -> Path {
                    Path(roundedRect: CGRect(x: x, y: 0, width: max(end - x, 0), height: size.height),
                         cornerRadius: radius)
                }

                context.fill(capsule(from: 0, to: full), with: .color(.gray.opacity(0.25)))

                if showsTarget {
                    let range = AppModel.comfortableRangeDB
                    let start = LevelMeter.position(ofDB: range.lowerBound) * full
                    let end = LevelMeter.position(ofDB: range.upperBound) * full
                    context.fill(
                        Path(CGRect(x: start, y: 0, width: end - start, height: size.height)),
                        with: .color(.green.opacity(0.25))
                    )
                }

                let filled = LevelMeter.position(ofLevel: level) * full
                if filled > 0 {
                    context.fill(
                        capsule(from: 0, to: filled),
                        with: .color(decibels > -3 ? .red : .accentColor)
                    )
                }

                if let peak, peak > 0 {
                    let peakDB = 20 * log10(peak)
                    let x = max(0, LevelMeter.position(ofDB: peakDB) * full - 2)
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                        with: .color(peakDB > -3 ? .red : .primary.opacity(0.6))
                    )
                }
            }
            .frame(width: width, height: 8)

            Text(decibels.isFinite ? String(format: "%.0f", decibels) : "\u{2013}")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
