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

    func applicationWillTerminate(_ notification: Notification) {
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

            LevelMeter(label: "In", level: model.inputLevel)
            LevelMeter(label: "Out", level: model.outputLevel)

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
struct LevelMeter: View {
    let label: String
    let level: Float

    /// A marker that hangs behind the bar, so a peak can be read after it has
    /// passed. Optional: only the input meter is something the user is aiming.
    var peak: Float?
    /// Shades the range a speaking voice should be landing in, which turns
    /// "how loud should this be" into "put the bar in the green".
    var showsTarget = false
    var width: CGFloat = 70

    private static let floorDB: Float = -60

    private var decibels: Float {
        level > 0 ? 20 * log10(level) : -.infinity
    }

    private func position(ofDB db: Float) -> Double {
        Double(min(max((db - LevelMeter.floorDB) / -LevelMeter.floorDB, 0), 1))
    }

    private var position: Double {
        decibels.isFinite ? position(ofDB: decibels) : 0
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)

            GeometryReader { geometry in
                let full = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)

                    if showsTarget {
                        let range = AppModel.comfortableRangeDB
                        let start = position(ofDB: range.lowerBound) * full
                        let end = position(ofDB: range.upperBound) * full
                        Rectangle()
                            .fill(.green.opacity(0.25))
                            .frame(width: end - start)
                            .offset(x: start)
                    }

                    Capsule()
                        .fill(decibels > -3 ? Color.red : Color.accentColor)
                        .frame(width: position * full)

                    if let peak, peak > 0 {
                        let peakDB = 20 * log10(peak)
                        Rectangle()
                            .fill(peakDB > -3 ? Color.red : Color.primary.opacity(0.6))
                            .frame(width: 2)
                            .offset(x: max(0, position(ofDB: peakDB) * full - 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: width, height: 8)

            Text(decibels.isFinite ? String(format: "%.0f", decibels) : "–")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
