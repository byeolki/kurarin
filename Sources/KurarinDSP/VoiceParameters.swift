import Foundation

/// Every knob the voice chain exposes.
///
/// One value type shared by the UI, the persistence layer and the audio thread.
/// It is the only contract between them, so adding a control means touching one
/// declaration rather than three parallel ones that can drift apart.
public struct VoiceParameters: Codable, Equatable, Sendable {
    public var inputGainDB: Float

    public var gateEnabled: Bool
    public var gateThresholdDB: Float

    public var highPassHz: Float

    public var pitchRatio: Float
    public var formantRatio: Float

    public var eqBands: [ParametricEQ.Band]

    public var driveAmount: Float
    public var driveBitDepth: Float
    public var driveDownsampleHz: Float
    public var driveMix: Float

    public var reverbRoomSize: Float
    public var reverbDamping: Float
    public var reverbMix: Float

    public var outputGainDB: Float

    public init(
        inputGainDB: Float = 0,
        gateEnabled: Bool = true,
        gateThresholdDB: Float = -45,
        highPassHz: Float = 80,
        pitchRatio: Float = 1,
        formantRatio: Float = 1,
        eqBands: [ParametricEQ.Band] = ParametricEQ.defaultBands,
        driveAmount: Float = 1,
        driveBitDepth: Float = 0,
        driveDownsampleHz: Float = 0,
        driveMix: Float = 1,
        reverbRoomSize: Float = 0.5,
        reverbDamping: Float = 0.5,
        reverbMix: Float = 0,
        outputGainDB: Float = 0
    ) {
        self.inputGainDB = inputGainDB
        self.gateEnabled = gateEnabled
        self.gateThresholdDB = gateThresholdDB
        self.highPassHz = highPassHz
        self.pitchRatio = pitchRatio
        self.formantRatio = formantRatio
        self.eqBands = eqBands
        self.driveAmount = driveAmount
        self.driveBitDepth = driveBitDepth
        self.driveDownsampleHz = driveDownsampleHz
        self.driveMix = driveMix
        self.reverbRoomSize = reverbRoomSize
        self.reverbDamping = reverbDamping
        self.reverbMix = reverbMix
        self.outputGainDB = outputGainDB
    }

    /// Decoding tolerates missing keys so presets saved by an older build keep
    /// loading after a parameter is added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceParameters()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        inputGainDB       = value(.inputGainDB, defaults.inputGainDB)
        gateEnabled       = value(.gateEnabled, defaults.gateEnabled)
        gateThresholdDB   = value(.gateThresholdDB, defaults.gateThresholdDB)
        highPassHz        = value(.highPassHz, defaults.highPassHz)
        pitchRatio        = value(.pitchRatio, defaults.pitchRatio)
        formantRatio      = value(.formantRatio, defaults.formantRatio)
        eqBands           = value(.eqBands, defaults.eqBands)
        driveAmount       = value(.driveAmount, defaults.driveAmount)
        driveBitDepth     = value(.driveBitDepth, defaults.driveBitDepth)
        driveDownsampleHz = value(.driveDownsampleHz, defaults.driveDownsampleHz)
        driveMix          = value(.driveMix, defaults.driveMix)
        reverbRoomSize    = value(.reverbRoomSize, defaults.reverbRoomSize)
        reverbDamping     = value(.reverbDamping, defaults.reverbDamping)
        reverbMix         = value(.reverbMix, defaults.reverbMix)
        outputGainDB      = value(.outputGainDB, defaults.outputGainDB)

        if eqBands.count != defaults.eqBands.count {
            eqBands = defaults.eqBands
        }
    }

    /// Clamps every value into the range its unit accepts.
    public func clamped() -> VoiceParameters {
        var result = self
        result.inputGainDB = min(max(inputGainDB, -24), 24)
        result.gateThresholdDB = min(max(gateThresholdDB, -80), 0)
        result.highPassHz = min(max(highPassHz, 20), 500)
        result.pitchRatio = min(max(pitchRatio, 0.5), 2)
        result.formantRatio = min(max(formantRatio, 0.5), 2)
        result.driveAmount = min(max(driveAmount, 1), 20)
        result.driveBitDepth = min(max(driveBitDepth, 0), 16)
        result.driveDownsampleHz = max(driveDownsampleHz, 0)
        result.driveMix = min(max(driveMix, 0), 1)
        result.reverbRoomSize = min(max(reverbRoomSize, 0), 0.98)
        result.reverbDamping = min(max(reverbDamping, 0), 1)
        result.reverbMix = min(max(reverbMix, 0), 1)
        result.outputGainDB = min(max(outputGainDB, -24), 24)
        result.eqBands = eqBands.map {
            ParametricEQ.Band(
                frequency: min(max($0.frequency, 20), 18000),
                q: min(max($0.q, 0.1), 12),
                gainDB: min(max($0.gainDB, -24), 24)
            )
        }
        return result
    }
}
