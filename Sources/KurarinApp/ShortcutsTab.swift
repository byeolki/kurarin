import SwiftUI
import KurarinSoundboard

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
                // Arming another recorder disarms this one, so two local event
                // monitors can never be installed at the same time.
                .onChange(of: model.recordingAction) { _, current in
                    if current != action { tearDown() }
                }

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
        model.beginRecordingHotKey(for: action)

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
        tearDown()
        model.endRecordingHotKey(for: action)
    }

    private func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
