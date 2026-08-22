import SwiftUI

@main
struct KurarinApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // The menu bar is the primary surface: quick toggles have to be
        // reachable without leaving a game, and the window is for setup.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRunning
                ? (model.isMuted ? "mic.slash.fill" : "waveform")
                : "waveform.slash")
        }

        Window("Kurarin", id: "main") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRunning ? "Stop" : "Start") { model.toggleRunning() }

        if model.isRunning {
            Toggle("Mute microphone", isOn: $model.isMuted)
            Toggle("Voice effect", isOn: $model.isEffectEnabled)
            Toggle("Hear myself", isOn: $model.monitorVoice)
        }

        Divider()

        Menu("Preset") {
            ForEach(model.presets) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if preset.id == model.selectedPresetID {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        }

        if model.slots.contains(where: { $0 != nil }) {
            Menu("Soundboard") {
                ForEach(Array(model.slots.enumerated()), id: \.offset) { index, slot in
                    if let slot {
                        Button(slot.name) { model.playSlot(index) }
                    }
                }
                Divider()
                Button("Stop all sounds") { model.stopAllSounds() }
            }
        }

        Divider()

        Button("Settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Kurarin") {
            model.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
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
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
