import XCTest
import KurarinDSP
@testable import KurarinPresets

final class PresetTests: XCTestCase {
    func testBuiltInIdentifiersAreUnique() {
        let ids = Set(Preset.builtIns.map(\.id))
        XCTAssertEqual(ids.count, Preset.builtIns.count)
    }

    func testBuiltInParametersSurviveClamping() {
        // A preset whose values get clamped on load is a preset that does not
        // sound the way it was designed to.
        for preset in Preset.builtIns {
            XCTAssertEqual(preset.parameters, preset.parameters.clamped(), preset.name)
        }
    }

    func testDuplicateIsEditableAndDistinct() {
        let original = Preset.builtIns[1]
        let copy = original.duplicated(named: "Mine")

        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.parameters, original.parameters)
        XCTAssertEqual(copy.name, "Mine")
    }

    func testParametersRoundTripThroughJSON() throws {
        let parameters = VoiceParameters(pitchRatio: 1.4, formantRatio: 0.9, reverbMix: 0.3)
        let data = try JSONEncoder().encode(parameters)
        XCTAssertEqual(try JSONDecoder().decode(VoiceParameters.self, from: data), parameters)
    }

    func testDecodingToleratesMissingKeys() throws {
        // Presets written by an earlier build must keep loading when a new
        // parameter is introduced.
        let partial = #"{"pitchRatio": 1.5}"#.data(using: .utf8)!
        let parameters = try JSONDecoder().decode(VoiceParameters.self, from: partial)

        XCTAssertEqual(parameters.pitchRatio, 1.5)
        XCTAssertEqual(parameters.formantRatio, VoiceParameters().formantRatio)
        XCTAssertEqual(parameters.eqBands.count, VoiceParameters().eqBands.count)
    }

    func testClampingBoundsOutOfRangeValues() {
        let wild = VoiceParameters(pitchRatio: 99, formantRatio: -3, reverbMix: 5).clamped()
        XCTAssertEqual(wild.pitchRatio, 2)
        XCTAssertEqual(wild.formantRatio, 0.5)
        XCTAssertEqual(wild.reverbMix, 1)
    }
}

final class PresetStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurarin-tests-\(UUID().uuidString)")
        store = PresetStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavedPresetIsLoadedBack() throws {
        let preset = Preset(name: "Mine", parameters: VoiceParameters(pitchRatio: 1.2))
        try store.save(preset)

        let loaded = store.loadUserPresets()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Mine")
        XCTAssertEqual(loaded.first?.parameters.pitchRatio, 1.2)
    }

    func testLoadAllIncludesBuiltIns() throws {
        try store.save(Preset(name: "Mine", parameters: VoiceParameters()))
        XCTAssertEqual(store.loadAll().count, Preset.builtIns.count + 1)
    }

    func testBuiltInCannotBeSavedOrDeleted() {
        let builtIn = Preset.builtIns[0]
        XCTAssertThrowsError(try store.save(builtIn))
        XCTAssertThrowsError(try store.delete(builtIn))
    }

    func testDeleteRemovesPreset() throws {
        let preset = Preset(name: "Temporary", parameters: VoiceParameters())
        try store.save(preset)
        XCTAssertEqual(store.loadUserPresets().count, 1)

        try store.delete(preset)
        XCTAssertTrue(store.loadUserPresets().isEmpty)
    }

    func testSavingClampsParameters() throws {
        let preset = Preset(name: "Wild", parameters: VoiceParameters(pitchRatio: 50))
        try store.save(preset)
        XCTAssertEqual(store.loadUserPresets().first?.parameters.pitchRatio, 2)
    }

    func testCorruptFileDoesNotBlockOtherPresets() throws {
        try store.save(Preset(name: "Good", parameters: VoiceParameters()))
        try "not json at all".write(
            to: directory.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = store.loadUserPresets()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Good")
    }

    func testMissingDirectoryLoadsEmpty() {
        let absent = PresetStore(directory: directory.appendingPathComponent("nope"))
        XCTAssertTrue(absent.loadUserPresets().isEmpty)
    }
}
