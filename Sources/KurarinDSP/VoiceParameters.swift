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

    /// How hard to duck mouse clicks, key presses and knocks. 0 is off.
    public var clickSuppression: Float

    /// How much steady background noise — fans, hum, hiss — to remove. 0 is off.
    public var noiseReduction: Float

    public var highPassHz: Float

    public var pitchRatio: Float
    public var formantRatio: Float

    /// Where the voice should end up, in hertz, rather than how far to move it.
    ///
    /// A ratio is the wrong unit for "sound like a woman". Multiplying a deep
    /// voice by 1.3 lands it between the two, and multiplying an already high
    /// one by the same amount overshoots — the same preset cannot work for two
    /// speakers. Aiming at a frequency instead lets the shifter work out the
    /// ratio from what it hears, which it can, because it is already tracking
    /// pitch to place its grains.
    ///
    /// Zero falls back to `pitchRatio`, which is what effects rather than
    /// impersonations want: a monster is a ratio, not a note.
    public var targetPitchHz: Float

    /// Aspiration noise, the cue that separates a voice from a pitch-shifted
    /// recording of one.
    public var breathiness: Float

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
        clickSuppression: Float = 0.6,
        noiseReduction: Float = 0.5,
        highPassHz: Float = 80,
        pitchRatio: Float = 1,
        formantRatio: Float = 1,
        targetPitchHz: Float = 0,
        breathiness: Float = 0,
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
        self.clickSuppression = clickSuppression
        self.noiseReduction = noiseReduction
        self.highPassHz = highPassHz
        self.pitchRatio = pitchRatio
        self.formantRatio = formantRatio
        self.targetPitchHz = targetPitchHz
        self.breathiness = breathiness
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
        clickSuppression  = value(.clickSuppression, defaults.clickSuppression)
        noiseReduction    = value(.noiseReduction, defaults.noiseReduction)
        highPassHz        = value(.highPassHz, defaults.highPassHz)
        pitchRatio        = value(.pitchRatio, defaults.pitchRatio)
        formantRatio      = value(.formantRatio, defaults.formantRatio)
        targetPitchHz     = value(.targetPitchHz, defaults.targetPitchHz)
        breathiness       = value(.breathiness, defaults.breathiness)
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
        result.clickSuppression = min(max(clickSuppression, 0), 1)
        result.noiseReduction = min(max(noiseReduction, 0), 1)
        result.highPassHz = min(max(highPassHz, 20), 500)
        result.pitchRatio = min(max(pitchRatio, 0.5), 2)
        result.formantRatio = min(max(formantRatio, 0.5), 2)
        // Zero means "use the ratio"; anything else has to be a pitch a person
        // could actually speak at.
        result.targetPitchHz = targetPitchHz <= 0 ? 0 : min(max(targetPitchHz, 60), 400)
        result.breathiness = min(max(breathiness, 0), 1)
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
