import SwiftUI
import UniformTypeIdentifiers
import KurarinDSP
import KurarinEngine
import KurarinSoundboard

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

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(min(level, 1)))
                .frame(width: 70)
                // Clipping is what a listener notices first, so the meter turns
                // red before the signal actually reaches full scale.
                .tint(level > 0.9 ? .red : .accentColor)
        }
    }
}

// MARK: - Devices

struct DevicesTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if !model.isDriverInstalled {
                Section {
                    Label(
                        "The Kurarin virtual microphone is not installed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Text("Run `sudo ./scripts/install-driver.sh` from the project directory, then reopen this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Input") {
                Picker("Microphone", selection: $model.selectedMicrophoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
            }

            Section("Monitoring") {
                Picker("Headphones", selection: $model.selectedMonitorUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.outputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Toggle("Hear my own transformed voice", isOn: $model.monitorVoice)
            }

            Section("System audio") {
                Picker("Share sound from", selection: $model.captureMode) {
                    ForEach(AppModel.CaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Captured apps keep playing normally through your headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.captureMode == .chosenApps {
                    CapturedAppList()
                }
                if model.captureMode != .off {
                    Slider(value: $model.captureGain, in: 0...2) {
                        Text("Shared sound level")
                    }
                }
            }

            Section("Quality") {
                Picker("Latency", selection: $model.latencyMode) {
                    Text("Low").tag(LatencyMode.low)
                    Text("Balanced").tag(LatencyMode.balanced)
                    Text("Quality").tag(LatencyMode.quality)
                }
                .pickerStyle(.segmented)
                Text("Higher quality follows lower voices more accurately, at the cost of delay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Make Kurarin the system default microphone while running", isOn: $model.takeOverSystemInput)
                Text("Needed for apps with no microphone picker, such as Roblox. Your previous choice is restored on stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Refresh device list") { model.refreshDevices() }
            }
        }
        .formStyle(.grouped)
    }
}

/// The apps whose sound is shared, chosen one by one.
///
/// Only processes Core Audio currently knows about can be listed, so an app
/// that has never played a sound this session will not appear until it does.
struct CapturedAppList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.audioProcesses.isEmpty {
                Text("No app is playing audio right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.audioProcesses) { app in
                    Toggle(isOn: Binding(
                        get: { model.capturedBundleIDs.contains(app.bundleID) },
                        set: { model.setCaptured($0, bundleID: app.bundleID) }
                    )) {
                        HStack(spacing: 6) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            Text(app.name)
                        }
                    }
                }
            }

            Button("Refresh list") { model.refreshAudioProcesses() }
                .controlSize(.small)
        }
        .onAppear { model.refreshAudioProcesses() }
    }
}

// MARK: - Voice

struct VoiceTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var presetName = ""

    var body: some View {
        HSplitView {
            List(model.presets, selection: Binding(
                get: { model.selectedPresetID },
                set: { id in
                    if let preset = model.presets.first(where: { $0.id == id }) {
                        model.selectPreset(preset)
                        presetName = preset.name
                    }
                }
            )) { preset in
                HStack {
                    Text(preset.name)
                    if preset.isBuiltIn {
                        Spacer()
                        Image(systemName: "lock").foregroundStyle(.tertiary)
                    }
                }
                .tag(preset.id)
            }
            .frame(minWidth: 160, maxWidth: 220)

            Form {
                Section("Voice") {
                    Toggle("Effect enabled", isOn: $model.isEffectEnabled)

                    LabeledRatio(
                        title: "Pitch",
                        value: $model.editedParameters.pitchRatio,
                        caption: "How high the voice sits."
                    )
                    LabeledRatio(
                        title: "Formant",
                        value: $model.editedParameters.formantRatio,
                        caption: "How large the speaker sounds. Move this with pitch to avoid a chipmunk."
                    )
                }

                Section("Cleanup") {
                    Toggle("Noise gate", isOn: $model.editedParameters.gateEnabled)
                    Slider(value: $model.editedParameters.gateThresholdDB, in: -80...0) {
                        Text("Gate threshold")
                    }
                    Slider(value: $model.editedParameters.highPassHz, in: 20...500) {
                        Text("Low cut")
                    }
                }

                Section("Character") {
                    Slider(value: $model.editedParameters.driveAmount, in: 1...20) { Text("Drive") }
                    Slider(value: $model.editedParameters.driveBitDepth, in: 0...16) { Text("Bit crush") }
                    Slider(value: $model.editedParameters.driveDownsampleHz, in: 0...24000) { Text("Sample rate crush") }
                    Slider(value: $model.editedParameters.reverbMix, in: 0...1) { Text("Reverb") }
                }

                Section("Level") {
                    Slider(value: $model.editedParameters.inputGainDB, in: -24...24) { Text("Input gain") }
                    Slider(value: $model.editedParameters.outputGainDB, in: -24...24) { Text("Output gain") }
                }

                Section {
                    HStack {
                        TextField("Preset name", text: $presetName)
                        Button("Save as preset") {
                            model.saveEdits(named: presetName.isEmpty ? "Untitled" : presetName)
                        }
                        Button("Delete") { model.deleteSelectedPreset() }
                            .disabled(model.selectedPreset?.isBuiltIn ?? true)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: model.editedParameters) { _, _ in model.applyCurrentPreset() }
        .onAppear { presetName = model.selectedPreset?.name ?? "" }
    }
}

struct LabeledRatio: View {
    let title: String
    @Binding var value: Float
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f×", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0.5...2.0)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Soundboard

struct SoundboardTab: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<SoundboardMixer.slotCount, id: \.self) { index in
                    SlotTile(index: index)
                }
            }
            .padding(4)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Stop all sounds") { model.stopAllSounds() }
                Spacer()
                Text("Drop an audio file onto a slot to assign it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SlotTile: View {
    @EnvironmentObject private var model: AppModel
    let index: Int
    @State private var isTargeted = false

    private var slot: SoundboardSlot? { model.slots[safe: index] ?? nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if slot != nil {
                    Button {
                        model.clearSlot(index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }

            if let slot {
                Text(slot.name).lineLimit(1).font(.callout)
                if let error = model.slotErrors[index] {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                } else {
                    HStack(spacing: 6) {
                        Button("Play") { model.playSlot(index) }
                        Button("Stop") { model.stopSlot(index) }
                    }
                    .controlSize(.small)

                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.tertiary)
                        Slider(
                            value: Binding(
                                get: { slot.volume },
                                set: { model.setVolume($0, for: index) }
                            ),
                            in: 0...2
                        )
                    }
                    Toggle("Loop", isOn: Binding(
                        get: { slot.loops },
                        set: { model.setLoops($0, for: index) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            } else {
                Text("Empty").foregroundStyle(.tertiary).font(.callout)
                Button("Choose…") { model.chooseFile(for: index) }
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            if let shortcut = model.shortcutName(forSlot: index) {
                Text(shortcut).font(.caption2).monospaced().foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(height: 150, alignment: .topLeading)
        .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.assign(url: url, to: index) }
            }
            return true
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsTab: View {
    @EnvironmentObject private var model: AppModel

    private let globalActions: [HotKeyManager.Action] = [
        .toggleMute, .toggleEffect, .previousPreset, .nextPreset, .stopSoundboard,
    ]

    var body: some View {
        Form {
            Section("Global") {
                ForEach(globalActions, id: \.self) { action in
                    LabeledContent(action.displayName) {
                        HotKeyRecorder(action: action)
                    }
                }
            }

            Section("Soundboard slots") {
                ForEach(0..<SoundboardMixer.slotCount, id: \.self) { index in
                    if let action = HotKeyManager.Action(rawValue: "playSlot\(index)") {
                        LabeledContent(model.slots[safe: index]??.name ?? "Slot \(index + 1)") {
                            HotKeyRecorder(action: action)
                        }
                    }
                }
            }

            Section {
                Text("These work while another app has focus, so they reach you mid-game. Function keys are the safest choice: a combination another app already holds cannot be registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, press a combination, done. Escape cancels.
///
/// The keys are read through a local event monitor rather than SwiftUI's key
/// handling, because what has to be captured is the raw key code Carbon
/// registers with, not the character the keyboard layout produces.
struct HotKeyRecorder: View {
    let action: HotKeyManager.Action
    @EnvironmentObject private var model: AppModel

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(label) { isRecording ? cancel() : startRecording() }
                .monospaced()
                .frame(minWidth: 90)

            Button {
                model.clearHotKey(for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(model.hotKeys[action] == nil ? 0 : 1)
            .disabled(model.hotKeys[action] == nil)
        }
        .onDisappear(perform: cancel)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return model.hotKeys[action]?.displayName ?? "Unassigned"
    }

    private func startRecording() {
        isRecording = true
        model.beginRecordingHotKey()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                cancel()
                return nil
            }
            if let hotKey = HotKey(event: event) {
                model.assign(hotKey, to: action)
                finish()
            }
            // Swallowed either way: a key pressed at the recorder should never
            // also reach the window behind it.
            return nil
        }
    }

    private func cancel() {
        guard isRecording else { return }
        finish()
    }

    private func finish() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        model.endRecordingHotKey()
    }
}
