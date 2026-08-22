import SwiftUI
import KurarinDSP

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

                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Aim for a pitch", isOn: Binding(
                            get: { model.editedParameters.targetPitchHz > 0 },
                            set: { model.editedParameters.targetPitchHz = $0 ? 200 : 0 }
                        ))
                        if model.editedParameters.targetPitchHz > 0 {
                            HStack {
                                Slider(value: $model.editedParameters.targetPitchHz, in: 70...320)
                                Text(String(format: "%.0f Hz", model.editedParameters.targetPitchHz))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            Text("Lands your voice on this pitch whoever you are, by measuring where it normally sits — a multiplier that suits a deep voice overshoots a light one. Men speak around 110 Hz, women around 200, children around 255.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Added below the explanation rather than replacing
                            // it, unlike the hum line: the reference pitches
                            // are what the slider is set against, and they are
                            // wanted most while it is running.
                            if let status = model.pitchDescription {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }

                    if model.editedParameters.targetPitchHz <= 0 {
                        LabeledRatio(
                            title: "Pitch",
                            value: $model.editedParameters.pitchRatio,
                            caption: "How high the voice sits."
                        )
                    }
                    LabeledRatio(
                        title: "Formant",
                        value: $model.editedParameters.formantRatio,
                        caption: "How large the speaker sounds. Move this with pitch to avoid a chipmunk."
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.breathiness, in: 0...1) {
                            Text("Breath")
                        }
                        Text("Aspiration noise. A pitch shifter moves the harmonics and leaves this behind, which is most of why a shifted voice sounds shifted rather than like somebody else. Female voices carry more of it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cleanup") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.humRemoval, in: 0...1) {
                            Text("Mains hum")
                        }
                        Text(model.humDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.noiseReduction, in: 0...1) {
                            Text("Background noise")
                        }
                        Text("Fans, air conditioning, computer hum, preamp hiss — the noise a gate can only cut between words. It learns the room while you are not speaking, so give it a second of quiet after starting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.clickSuppression, in: 0...1) {
                            Text("Click and key noise")
                        }
                        Text("Removes mouse clicks, typing and knocks. It knows a held vowel from a click by its pitch, so turning it up does not eat the end of an “aaah”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Noise gate", isOn: $model.editedParameters.gateEnabled)
                    Slider(value: $model.editedParameters.gateThresholdDB, in: -80...0) {
                        Text("Gate threshold")
                    }
                    Slider(value: $model.editedParameters.highPassHz, in: 20...500) {
                        Text("Low cut")
                    }
                }

                Section("Realism") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.highBandResynthesis, in: 0...1) {
                            Text("Rebuild the air")
                        }
                        Text("Above five kilohertz a voice is breath and hiss rather than harmonics, and a pitch shifter repeats it into a buzz on the new note. Rebuilding it as fresh noise is what stops a shifted voice sounding shifted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $model.editedParameters.formantCorrection, in: 0...1) {
                            Text("Vocal tract correction")
                        }
                        Text("A shorter vocal tract raises its upper resonances more than its lower ones. The shifter moves them all by the same amount, and this tilts the result back towards the uneven way anatomy actually changes size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Equaliser") {
                    EqualiserEditor(bands: $model.editedParameters.eqBands)
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

/// The five bands, in the order the chain applies them.
///
/// Every preset already carries a curve; without this the curve could only be
/// changed by editing the JSON by hand. Frequency and gain are on sliders, and
/// Q is left to the preset — three controls per band is more knobs than the
/// difference is worth for most people, and the outer bands are shelves where Q
/// barely matters.
struct EqualiserEditor: View {
    @Binding var bands: [ParametricEQ.Band]

    private static let roles = ["Low shelf", "Low mid", "Mid", "High mid", "High shelf"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bands.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(EqualiserEditor.roles[safe: index] ?? "Band \(index + 1)")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f Hz  %+.1f dB", bands[index].frequency, bands[index].gainDB))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: gain(at: index), in: -18...18)
                    Slider(value: frequency(at: index), in: 0...1)
                        .controlSize(.mini)
                }
            }

            Button("Flatten") {
                for index in bands.indices { bands[index].gainDB = 0 }
            }
            .controlSize(.small)
        }
    }

    private func gain(at index: Int) -> Binding<Float> {
        Binding(
            get: { bands[safe: index]?.gainDB ?? 0 },
            set: { if bands.indices.contains(index) { bands[index].gainDB = $0 } }
        )
    }

    private static let lowest: Float = 20
    private static let highest: Float = 18000

    /// Position on the slider, not hertz. Pitch is logarithmic, so a linear
    /// frequency slider spends four fifths of its travel above 4 kHz and makes
    /// the bands that shape a voice impossible to place.
    private func frequency(at index: Int) -> Binding<Float> {
        let span = log(EqualiserEditor.highest / EqualiserEditor.lowest)
        return Binding(
            get: {
                let hertz = bands[safe: index]?.frequency ?? 1000
                return log(hertz / EqualiserEditor.lowest) / span
            },
            set: { position in
                guard bands.indices.contains(index) else { return }
                bands[index].frequency = EqualiserEditor.lowest * exp(position * span)
            }
        )
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
