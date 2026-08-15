import Foundation
import CoreAudio
import SwiftUI
import Combine
import KurarinDSP
import KurarinEngine
import KurarinPresets
import KurarinSoundboard

@MainActor
final class AppModel: ObservableObject {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case off, entireSystem, chosenApps
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .off:          return "Off"
            case .entireSystem: return "Everything"
            case .chosenApps:   return "Chosen apps"
            }
        }
    }

    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var isDriverInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?

    @Published var selectedMicrophoneUID: String? { didSet { persistAndRestart(oldValue, selectedMicrophoneUID) } }
    @Published var selectedMonitorUID: String? { didSet { persistAndRestart(oldValue, selectedMonitorUID) } }
    @Published var latencyMode: LatencyMode = .balanced { didSet { persistAndRestart(oldValue, latencyMode) } }
    @Published var captureMode: CaptureMode = .off { didSet { persistAndRestart(oldValue, captureMode) } }

    @Published var isMuted = false { didSet { engine.isMuted = isMuted } }
    @Published var isEffectEnabled = true { didSet { applyCurrentPreset() } }
    @Published var monitorVoice = false { didSet { engine.monitorVoice = monitorVoice } }
    @Published var takeOverSystemInput = true { didSet { defaults.set(takeOverSystemInput, forKey: Keys.takeOver) } }

    @Published private(set) var presets: [Preset] = []
    @Published var selectedPresetID: UUID?
    @Published var editedParameters = VoiceParameters()

    @Published var slots: [SoundboardSlot?] = Array(repeating: nil, count: SoundboardMixer.slotCount)
    @Published private(set) var slotErrors: [Int: String] = [:]

    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0

    @Published var hotKeys: [HotKeyManager.Action: HotKey] = HotKeyManager.defaults

    let engine = KurarinEngine()
    private let store = PresetStore()
    private let hotKeyManager = HotKeyManager()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    private var deviceObserver: AudioDevices.Observer?
    private var previousDefaultInput: AudioDeviceInfo?
    private var isRestoring = true

    private enum Keys {
        static let microphone = "microphoneUID"
        static let monitor = "monitorUID"
        static let latency = "latencyMode"
        static let capture = "captureMode"
        static let preset = "selectedPreset"
        static let slots = "soundboardSlots"
        static let hotKeys = "hotKeys"
        static let takeOver = "takeOverSystemInput"
        static let displacedInput = "displacedInputUID"
    }

    init() {
        refreshDevices()
        presets = store.loadAll()
        restoreSettings()
        isRestoring = false
        returnDisplacedInputDevice()

        // Quitting from the Dock, from another app's menu or by logging out
        // never reaches the menu bar's Quit item, and leaving the system input
        // pointed at a silent virtual device would break the microphone for
        // every other application.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        hotKeyManager.handler = { [weak self] action in
            self?.perform(action)
        }
        registerHotKeys()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }

        deviceObserver = AudioDevices.Observer { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        inputDevices = AudioDevices.inputDevices()
        outputDevices = AudioDevices.outputDevices()
        isDriverInstalled = AudioDevices.isDriverInstalled
    }

    /// A device came or went. Only a device the engine is currently using is
    /// worth acting on; anything else just refreshes the pickers.
    private func devicesChanged() {
        refreshDevices()
        guard isRunning else { return }

        if let microphone = engine.configuration.microphone,
           !inputDevices.contains(where: { $0.uid == microphone.uid }) {
            fallBackToDefaults(after: "\(microphone.name) was disconnected")
            return
        }
        if let monitor = engine.configuration.monitor,
           !outputDevices.contains(where: { $0.uid == monitor.uid }) {
            fallBackToDefaults(after: "\(monitor.name) was disconnected")
        }
    }

    /// Clears any selection that no longer resolves and restarts on whatever the
    /// system considers default, rather than leaving a running engine attached
    /// to a device that is gone.
    private func fallBackToDefaults(after reason: String) {
        isRestoring = true
        if let uid = selectedMicrophoneUID, !inputDevices.contains(where: { $0.uid == uid }) {
            selectedMicrophoneUID = nil
        }
        if let uid = selectedMonitorUID, !outputDevices.contains(where: { $0.uid == uid }) {
            selectedMonitorUID = nil
        }
        isRestoring = false
        saveSettings()

        stop()
        start()
        if statusMessage == nil {
            statusMessage = "\(reason). Switched to the system default."
        }
    }

    private var selectedMicrophone: AudioDeviceInfo? {
        inputDevices.first { $0.uid == selectedMicrophoneUID } ?? AudioDevices.defaultInputDevice()
    }

    private var selectedMonitor: AudioDeviceInfo? {
        outputDevices.first { $0.uid == selectedMonitorUID } ?? AudioDevices.defaultOutputDevice()
    }

    // MARK: - Engine

    func start() {
        refreshDevices()
        guard isDriverInstalled else {
            statusMessage = AudioDeviceError.driverNotInstalled.localizedDescription
            return
        }

        var configuration = KurarinEngine.Configuration()
        configuration.microphone = selectedMicrophone
        configuration.monitor = selectedMonitor
        configuration.latencyMode = latencyMode
        switch captureMode {
        case .off:          configuration.captureSource = nil
        case .entireSystem: configuration.captureSource = .entireSystem
        case .chosenApps:   configuration.captureSource = .processes(chosenProcessIDs)
        }

        do {
            try engine.start(configuration)
            engine.isMuted = isMuted
            engine.monitorVoice = monitorVoice
            applyCurrentPreset()
            reloadAllSlots()
            isRunning = true
            statusMessage = nil

            if takeOverSystemInput, let virtualDevice = AudioDevices.virtualDevice() {
                // Roblox and similar clients have no microphone picker and just
                // follow the system default, so this is the only way to reach
                // them. The previous choice is restored on stop.
                let displaced = AudioDevices.defaultInputDevice()
                previousDefaultInput = displaced
                // Also on disk: if the app is killed rather than quit, the next
                // launch is the only chance to undo this.
                defaults.set(displaced?.uid, forKey: Keys.displacedInput)
                AudioDevices.setDefaultInputDevice(virtualDevice)
            }
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        inputLevel = 0
        outputLevel = 0

        if let previousDefaultInput {
            AudioDevices.setDefaultInputDevice(previousDefaultInput)
            self.previousDefaultInput = nil
        }
        defaults.removeObject(forKey: Keys.displacedInput)
    }

    /// Undoes a takeover that a previous run never got to undo.
    ///
    /// Only acts when the system is still pointed at the virtual device: if the
    /// user has since chosen something else, that choice is theirs to keep.
    private func returnDisplacedInputDevice() {
        guard let uid = defaults.string(forKey: Keys.displacedInput) else { return }
        defaults.removeObject(forKey: Keys.displacedInput)

        guard AudioDevices.defaultInputDevice()?.uid == AudioDevices.virtualDeviceUID,
              let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        AudioDevices.setDefaultInputDevice(device)
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    var latencyDescription: String {
        let milliseconds = engine.latencySeconds * 1000
        return String(format: "%.0f ms", milliseconds)
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func persistAndRestart<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard !isRestoring, oldValue != newValue else { return }
        saveSettings()
        restartIfRunning()
    }

    private func pollMeters() {
        guard isRunning else { return }
        inputLevel = engine.inputLevel
        outputLevel = engine.outputLevel
    }

    // MARK: - Presets

    var selectedPreset: Preset? {
        presets.first { $0.id == selectedPresetID }
    }

    func selectPreset(_ preset: Preset) {
        selectedPresetID = preset.id
        editedParameters = preset.parameters
        defaults.set(preset.id.uuidString, forKey: Keys.preset)
        applyCurrentPreset()
    }

    func applyCurrentPreset() {
        engine.apply(isEffectEnabled ? editedParameters : VoiceParameters())
    }

    /// Saves the current edits. Built-ins are copied rather than overwritten so
    /// the shipped starting points stay intact.
    func saveEdits(named name: String) {
        let preset: Preset
        if let current = selectedPreset, !current.isBuiltIn {
            var updated = current
            updated.name = name
            updated.parameters = editedParameters
            preset = updated
        } else {
            preset = Preset(name: name, parameters: editedParameters)
        }

        do {
            let saved = try store.save(preset)
            presets = store.loadAll()
            selectedPresetID = saved.id
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSelectedPreset() {
        guard let preset = selectedPreset, !preset.isBuiltIn else { return }
        try? store.delete(preset)
        presets = store.loadAll()
        selectedPresetID = presets.first?.id
        if let first = presets.first { selectPreset(first) }
    }

    func cyclePreset(by offset: Int) {
        guard !presets.isEmpty else { return }
        let currentIndex = presets.firstIndex { $0.id == selectedPresetID } ?? 0
        let count = presets.count
        let next = ((currentIndex + offset) % count + count) % count
        selectPreset(presets[next])
    }

    // MARK: - Soundboard

    func assign(url: URL, to index: Int) {
        guard slots.indices.contains(index) else { return }
        let slot = SoundboardSlot(name: url.deletingPathExtension().lastPathComponent, fileURL: url)
        slots[index] = slot
        loadSlot(index)
        saveSettings()
    }

    func clearSlot(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = nil
        slotErrors[index] = nil
        engine.soundboard.clear(slot: index)
        saveSettings()
    }

    func playSlot(_ index: Int) {
        guard let slot = slots[safe: index] ?? nil else { return }
        engine.soundboard.play(slot: index, gain: slot.volume, loops: slot.loops)
    }

    func stopAllSounds() {
        engine.soundboard.stopAll()
    }

    private func loadSlot(_ index: Int) {
        guard let slot = slots[safe: index] ?? nil else { return }
        do {
            let samples = try SampleLoader.load(slot.fileURL, sampleRate: 48000)
            engine.soundboard.install(samples, at: index)
            slotErrors[index] = nil
        } catch {
            // Surfaced on the slot itself. The audio thread never sees a file
            // that failed to load.
            slotErrors[index] = error.localizedDescription
        }
    }

    private func reloadAllSlots() {
        for index in slots.indices where slots[index] != nil {
            loadSlot(index)
        }
    }

    private var chosenProcessIDs: [AudioObjectID] {
        SystemAudioTap.audioProcesses().map(\.id)
    }

    // MARK: - Hot keys

    func registerHotKeys() {
        hotKeyManager.unregisterAll()
        for (action, hotKey) in hotKeys {
            hotKeyManager.register(hotKey, for: action)
        }
        for index in 0..<SoundboardMixer.slotCount {
            guard let action = HotKeyManager.Action(rawValue: "playSlot\(index)"),
                  let hotKey = hotKeys[action] else { continue }
            hotKeyManager.register(hotKey, for: action)
        }
    }

    private func perform(_ action: HotKeyManager.Action) {
        switch action {
        case .toggleMute:      isMuted.toggle()
        case .toggleEffect:    isEffectEnabled.toggle()
        case .nextPreset:      cyclePreset(by: 1)
        case .previousPreset:  cyclePreset(by: -1)
        case .stopSoundboard:  stopAllSounds()
        default:
            if let index = action.slotIndex { playSlot(index) }
        }
    }

    // MARK: - Persistence

    private func saveSettings() {
        defaults.set(selectedMicrophoneUID, forKey: Keys.microphone)
        defaults.set(selectedMonitorUID, forKey: Keys.monitor)
        defaults.set(latencyMode.rawValue, forKey: Keys.latency)
        defaults.set(captureMode.rawValue, forKey: Keys.capture)
        defaults.set(takeOverSystemInput, forKey: Keys.takeOver)

        if let data = try? JSONEncoder().encode(slots) {
            defaults.set(data, forKey: Keys.slots)
        }
        if let data = try? JSONEncoder().encode(hotKeys.mapKeys { $0.rawValue }) {
            defaults.set(data, forKey: Keys.hotKeys)
        }
    }

    private func restoreSettings() {
        selectedMicrophoneUID = defaults.string(forKey: Keys.microphone)
        selectedMonitorUID = defaults.string(forKey: Keys.monitor)
        if let raw = defaults.string(forKey: Keys.latency), let mode = LatencyMode(rawValue: raw) {
            latencyMode = mode
        }
        if let raw = defaults.string(forKey: Keys.capture), let mode = CaptureMode(rawValue: raw) {
            captureMode = mode
        }
        if defaults.object(forKey: Keys.takeOver) != nil {
            takeOverSystemInput = defaults.bool(forKey: Keys.takeOver)
        }
        if let data = defaults.data(forKey: Keys.slots),
           let stored = try? JSONDecoder().decode([SoundboardSlot?].self, from: data),
           stored.count == slots.count {
            slots = stored
        }
        if let data = defaults.data(forKey: Keys.hotKeys),
           let stored = try? JSONDecoder().decode([String: HotKey].self, from: data) {
            var restored: [HotKeyManager.Action: HotKey] = [:]
            for (raw, hotKey) in stored {
                if let action = HotKeyManager.Action(rawValue: raw) { restored[action] = hotKey }
            }
            if !restored.isEmpty { hotKeys = restored }
        }

        let storedPreset = defaults.string(forKey: Keys.preset).flatMap(UUID.init(uuidString:))
        if let preset = presets.first(where: { $0.id == storedPreset }) ?? presets.first {
            selectedPresetID = preset.id
            editedParameters = preset.parameters
        }
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
