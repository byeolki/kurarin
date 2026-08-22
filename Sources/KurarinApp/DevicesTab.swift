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
                        LevelMeter(
                            label: "In",
                            level: model.inputLevel,
                            peak: model.inputPeak,
                            showsTarget: true,
                            width: 150
                        )

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
