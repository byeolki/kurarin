import Foundation
import KurarinDSP

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parameters: VoiceParameters

    /// Built-in presets ship with the app and cannot be overwritten. Editing one
    /// produces a copy, so the originals stay available as a starting point.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, parameters: VoiceParameters, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.isBuiltIn = isBuiltIn
    }

    /// Returns an editable copy of a built-in preset.
    public func duplicated(named newName: String? = nil) -> Preset {
        Preset(
            id: UUID(),
            name: newName ?? "\(name) copy",
            parameters: parameters,
            isBuiltIn: false
        )
    }
}

public extension Preset {
    /// Fixed identifiers so a user's choice of built-in preset survives an
    /// upgrade.
    private static func builtInID(_ suffix: String) -> UUID {
        UUID(uuidString: "0000A11A-0000-4000-A000-0000000000\(suffix)")!
    }

    static let builtIns: [Preset] = [
        Preset(
            id: builtInID("01"),
            name: "Neutral",
            parameters: VoiceParameters(),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("02"),
            name: "Child",
            parameters: VoiceParameters(
                pitchRatio: 1.55,
                // Formants move less than the fundamental. A child's vocal tract
                // is shorter, but not in the same proportion as the pitch is
                // higher; matching the two exactly is what makes a chipmunk.
                formantRatio: 1.32,
                eqBands: [
                    .init(frequency: 150,  q: 0.707, gainDB: -4),
                    .init(frequency: 400,  q: 1.0,   gainDB: -2),
                    .init(frequency: 1600, q: 1.0,   gainDB: 2),
                    .init(frequency: 4000, q: 1.0,   gainDB: 3),
                    .init(frequency: 9000, q: 0.707, gainDB: 2),
                ]
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("03"),
            name: "Deep Male",
            parameters: VoiceParameters(
                pitchRatio: 0.72,
                formantRatio: 0.84,
                eqBands: [
                    .init(frequency: 110,  q: 0.707, gainDB: 4),
                    .init(frequency: 300,  q: 1.0,   gainDB: 2),
                    .init(frequency: 1400, q: 1.0,   gainDB: -1),
                    .init(frequency: 3500, q: 1.0,   gainDB: -2),
                    .init(frequency: 9000, q: 0.707, gainDB: -3),
                ]
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("04"),
            name: "Female",
            parameters: VoiceParameters(
                pitchRatio: 1.28,
                formantRatio: 1.14,
                eqBands: [
                    .init(frequency: 130,  q: 0.707, gainDB: -3),
                    .init(frequency: 500,  q: 1.0,   gainDB: -1),
                    .init(frequency: 2200, q: 1.0,   gainDB: 2),
                    .init(frequency: 4500, q: 1.0,   gainDB: 2),
                    .init(frequency: 9000, q: 0.707, gainDB: 1),
                ]
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("05"),
            name: "Robot",
            parameters: VoiceParameters(
                highPassHz: 150,
                pitchRatio: 1.0,
                formantRatio: 1.0,
                eqBands: [
                    .init(frequency: 200,  q: 0.707, gainDB: -6),
                    .init(frequency: 700,  q: 3.0,   gainDB: 5),
                    .init(frequency: 1800, q: 3.0,   gainDB: 4),
                    .init(frequency: 3500, q: 1.0,   gainDB: -3),
                    .init(frequency: 9000, q: 0.707, gainDB: -8),
                ],
                driveAmount: 2.5,
                driveBitDepth: 6,
                // Sample rate reduction is what actually reads as mechanical;
                // saturation alone just sounds overdriven.
                driveDownsampleHz: 8000,
                driveMix: 0.85
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("06"),
            name: "Radio",
            parameters: VoiceParameters(
                highPassHz: 300,
                eqBands: [
                    .init(frequency: 300,  q: 0.707, gainDB: -18),
                    .init(frequency: 900,  q: 1.2,   gainDB: 4),
                    .init(frequency: 2000, q: 1.2,   gainDB: 6),
                    .init(frequency: 3200, q: 1.5,   gainDB: 3),
                    .init(frequency: 5000, q: 0.707, gainDB: -20),
                ],
                driveAmount: 5,
                driveMix: 0.7
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("07"),
            name: "Monster",
            parameters: VoiceParameters(
                pitchRatio: 0.55,
                formantRatio: 0.62,
                eqBands: [
                    .init(frequency: 100,  q: 0.707, gainDB: 6),
                    .init(frequency: 350,  q: 1.0,   gainDB: 3),
                    .init(frequency: 1200, q: 1.0,   gainDB: -2),
                    .init(frequency: 3500, q: 1.0,   gainDB: -4),
                    .init(frequency: 9000, q: 0.707, gainDB: -6),
                ],
                driveAmount: 3,
                driveMix: 0.5,
                reverbRoomSize: 0.6,
                reverbDamping: 0.7,
                reverbMix: 0.22
            ),
            isBuiltIn: true
        ),
        Preset(
            id: builtInID("08"),
            name: "Underwater",
            parameters: VoiceParameters(
                pitchRatio: 0.85,
                formantRatio: 0.88,
                eqBands: [
                    .init(frequency: 200,  q: 0.707, gainDB: 3),
                    .init(frequency: 600,  q: 1.5,   gainDB: 4),
                    .init(frequency: 1800, q: 1.0,   gainDB: -6),
                    .init(frequency: 4000, q: 1.0,   gainDB: -12),
                    .init(frequency: 8000, q: 0.707, gainDB: -18),
                ],
                reverbRoomSize: 0.85,
                reverbDamping: 0.8,
                reverbMix: 0.45
            ),
            isBuiltIn: true
        ),
    ]
}
