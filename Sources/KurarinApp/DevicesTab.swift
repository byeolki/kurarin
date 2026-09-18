import SwiftUI
import KurarinDSP

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

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Microphone gain")
                        Spacer()
                        Text(String(format: "%+.0f dB", model.inputTrimDB))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.inputTrimDB, in: -12...36)

                    HStack(spacing: 10) {
                        InputMeter(meters: model.meters)

                        if model.calibrationRemaining > 0 {
                            Button("Cancel") { model.cancelCalibration() }
                                .controlSize(.small)
                            Text("Listening — speak normally…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Set from my voice") { model.calibrateInputGain() }
                                .controlSize(.small)
                                .disabled(!model.isRunning)
                        }
                    }

                    Text("Talk normally and land the bar in the green. Many USB microphones have no software volume, so this is the only place to correct a quiet one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // The slider above cannot fix this, which is the whole
                    // reason for saying it out loud: the damage is done before
                    // the audio reaches us.
                    if model.isInputClipping {
                        Label(
                            "Your microphone is clipping. Turn its own gain down — in its hardware knob or in System Settings ▸ Sound ▸ Input. The slider here is applied afterwards and cannot undo it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Recording") {
                HStack {
                    Button(model.isRecording ? "Stop recording" : "Record screen") {
                        model.toggleRecording()
                    }
                    .disabled(!model.isRunning)

                    if model.isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Recording")
                            .foregroundStyle(.secondary)
                    } else if model.recordingURL != nil {
                        Button("Show in Finder") { model.revealRecording() }
                    }

                    Spacer()
                    Button("Open folder") { model.revealRecordingFolder() }
                }

                Text("Records the screen with the mix your listeners hear — the transformed voice, the soundboard and anything you are sharing. Not what comes out of your own headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Saved to \(model.recordingFolder.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                // Said before the button is pressed rather than after it fails.
                // macOS will not ask twice, and for an ad-hoc signed app it does
                // not ask at all, so there is nothing to discover by trying.
                if model.recordingNeedsPermission {
                    HStack(spacing: 6) {
                        Label(
                            "macOS has not granted screen recording to Kurarin. Turn it on, then come back.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        Button("Open settings") { model.openScreenRecordingSettings() }
                            .controlSize(.small)
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

/// Watches the meters rather than the model, so that a moving bar does not
/// rebuild the settings form around it.
private struct InputMeter: View {
    @ObservedObject var meters: Meters

    var body: some View {
        LevelMeter(
            label: "In",
            level: meters.input,
            decibels: meters.inputDecibels,
            peak: meters.inputPeak,
            showsTarget: true,
            width: 150
        )
    }
}
