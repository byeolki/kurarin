import SwiftUI
import UniformTypeIdentifiers
import KurarinSoundboard

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
                            in: 0...2,
                            // Saved once, when the drag ends: writing the slot
                            // list to disk on every frame of a drag is a lot of
                            // encoding for a value that is still moving.
                            onEditingChanged: { editing in
                                if !editing { model.commitSlotEdits() }
                            }
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
