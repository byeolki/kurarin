import Foundation
import AppKit
import os
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers
import Combine
import KurarinDSP
import KurarinEngine
import KurarinPresets
import KurarinSoundboard

/// Anything worth explaining after the fact goes here rather than only into the
/// status bar, which is gone the moment it is replaced.
let appLog = Logger(subsystem: "com.byeolki.kurarin", category: "app")

/// An app that can be captured, with the name and icon the user knows it by.
struct CapturableApp: Identifiable, Equatable {
    let id: AudioObjectID
    let bundleID: String
    let name: String
    let icon: NSImage?

    init(process: SystemAudioTap.ProcessInfo) {
        id = process.id
        bundleID = process.bundleID
        // A bundle identifier is not something to show a user, so it is only the
        // fallback for a process that is no longer running under its own name.
        let application = NSRunningApplication(processIdentifier: process.pid)
        name = application?.localizedName ?? process.bundleID
        icon = application?.icon
    }
}

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
    @Published var captureGain: Float = 1 {
        didSet {
            engine.systemCaptureGain = captureGain
            defaults.set(captureGain, forKey: Keys.captureGain)
        }
    }
    /// Listens for a few seconds and sets the gain so the loudest thing heard
    /// lands on the target.
    ///
    /// Reading a meter while dragging a slider is a two-handed job, and the
    /// answer is arithmetic: the difference between the peak of a normal
    /// speaking voice and where that peak should be is exactly how much gain
    /// is missing.
    func calibrateInputGain() {
        guard isRunning else {
            statusMessage = "Start the engine before setting the microphone gain."
            return
        }
        calibrationPeak = 0
        calibrationRemaining = 30 * 4      // four seconds of meter polls
    }

    func cancelCalibration() {
        calibrationRemaining = 0
        calibrationPeak = 0
    }

    private func finishCalibration() {
        defer { calibrationPeak = 0 }

        guard calibrationPeak > 0 else {
            statusMessage = "Heard nothing. Check the microphone and try again."
            return
        }
        let heardDB = 20 * log10(calibrationPeak)
        guard heardDB > -60 else {
            statusMessage = "Heard almost nothing — speak while it listens."
            return
        }

        // The trim is already in the measurement, so the correction is added to
        // it rather than replacing it.
        let corrected = inputTrimDB + (AppModel.targetPeakDB - heardDB)
        inputTrimDB = min(max(corrected, -12), 36)
        statusMessage = String(
            format: "Microphone gain set to %+.0f dB — your voice peaked at %.0f dB.",
            inputTrimDB, heardDB
        )
    }

    /// Microphone correction in decibels. A device-level setting, not part of
    /// a preset: it describes the hardware, not the voice.
    @Published var inputTrimDB: Float = 0 {
        didSet {
            engine.inputTrim = powf(10, inputTrimDB / 20)
            defaults.set(inputTrimDB, forKey: Keys.inputTrim)
        }
    }
    @Published private(set) var capturedBundleIDs: Set<String> = []
    @Published private(set) var audioProcesses: [CapturableApp] = []

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
    /// Falls far more slowly than the bar, so a peak stays readable.
    @Published private(set) var inputPeak: Float = 0

    /// Polls remaining in a calibration run, and the loudest thing heard so far.
    @Published private(set) var calibrationRemaining = 0
    private var calibrationPeak: Float = 0

    /// Where a speaking voice should peak. Loud enough to sit well above the
    /// noise floor and the gate, with room left for a shout before the limiter
    /// has to do anything about it.
    static let targetPeakDB: Float = -12
    static let comfortableRangeDB: ClosedRange<Float> = -18 ... -6

    private static let meterFall: Float = 0.82
    private static let peakFall: Float = 0.99

    @Published var hotKeys: [HotKeyManager.Action: HotKey] = HotKeyManager.defaults
    /// The action currently listening for a key press, if any. Published so
    /// that arming one recorder disarms whichever one was armed before.
    @Published private(set) var recordingAction: HotKeyManager.Action?

    let engine = KurarinEngine()
    private let store = PresetStore()
    private let hotKeyManager = HotKeyManager()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    private var meterTicks = 0
    private var slotSaveTimer: Timer?
    private var deviceObserver: AudioDevices.Observer?
    /// Held by UID, not by object: a device that has been unplugged in the
    /// meantime keeps its UID but gets a new object ID when it comes back, and
    /// restoring by a stale ID silently does nothing.
    private var previousDefaultInputUID: String?
    private var isRestoring = true

    private enum Keys {
        static let microphone = "microphoneUID"
        static let monitor = "monitorUID"
        static let latency = "latencyMode"
        static let capture = "captureMode"
        static let captureGain = "captureGain"
        static let inputTrim = "inputTrimDB"
        static let capturedApps = "capturedBundleIDs"
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
        // Only when the restart worked: if it did not, whatever start() has to
        // say about that matters more than which device went away.
        if isRunning {
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
            appLog.error("start refused: the virtual device is not installed")
            return
        }

        var configuration = KurarinEngine.Configuration()
        configuration.microphone = selectedMicrophone
        configuration.monitor = selectedMonitor
        configuration.latencyMode = latencyMode
        switch captureMode {
        case .off:          configuration.captureSource = nil
        case .entireSystem: configuration.captureSource = .entireSystem
        case .chosenApps:
            // A tap over no processes would only cost a permission prompt.
            let processes = chosenProcessIDs
            configuration.captureSource = processes.isEmpty ? nil : .processes(processes)
        }

        do {
            try engine.start(configuration)
            engine.isMuted = isMuted
            engine.monitorVoice = monitorVoice
            engine.systemCaptureGain = captureGain
            engine.inputTrim = powf(10, inputTrimDB / 20)
            applyCurrentPreset()
            reloadAllSlots()
            isRunning = true
            statusMessage = engine.captureFailure

            if takeOverSystemInput, let virtualDevice = AudioDevices.virtualDevice() {
                // Roblox and similar clients have no microphone picker and just
                // follow the system default, so this is the only way to reach
                // them. The previous choice is restored on stop.
                // Never records the virtual device as the thing to go back to:
                // a previous run that ended badly can leave the system already
                // pointed at it, and restoring to it would make the recovery
                // path preserve exactly the state it exists to undo.
                let displaced = AudioDevices.defaultInputDevice()
                    .map(\.uid)
                    .flatMap { $0 == AudioDevices.virtualDeviceUID ? nil : $0 }
                previousDefaultInputUID = displaced
                // Also on disk: if the app is killed rather than quit, the next
                // launch is the only chance to undo this.
                if let displaced {
                    defaults.set(displaced, forKey: Keys.displacedInput)
                }
                AudioDevices.setDefaultInputDevice(virtualDevice)
            }
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
            appLog.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        inputLevel = 0
        outputLevel = 0

        if let uid = previousDefaultInputUID {
            previousDefaultInputUID = nil
            restoreDefaultInput(preferring: uid)
        }
        defaults.removeObject(forKey: Keys.displacedInput)
    }

    /// Points the system back at a real microphone.
    ///
    /// Leaves a choice the user made themselves while the engine was running
    /// alone, and falls back to any real input if the one that was displaced has
    /// since been unplugged — anything is better than leaving the machine on a
    /// virtual device with nothing writing to it.
    private func restoreDefaultInput(preferring uid: String) {
        guard AudioDevices.systemDefaultInputUID() == AudioDevices.virtualDeviceUID else { return }

        let devices = AudioDevices.inputDevices()
        let replacement = devices.first { $0.uid == uid }
            ?? devices.first { !$0.isVirtual }
            ?? devices.first
        guard let replacement else { return }
        AudioDevices.setDefaultInputDevice(replacement)
    }

    /// Undoes a takeover that a previous run never got to undo.
    ///
    /// Only acts when the system is still pointed at the virtual device: if the
    /// user has since chosen something else, that choice is theirs to keep.
    private func returnDisplacedInputDevice() {
        guard let uid = defaults.string(forKey: Keys.displacedInput) else { return }
        defaults.removeObject(forKey: Keys.displacedInput)

        guard AudioDevices.systemDefaultInputUID() == AudioDevices.virtualDeviceUID,
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

        let levels = engine.drainLevels()
        // Ballistics: jump to a new peak, fall back gently. An instantaneous
        // meter flickers too fast to read; one that only rises never comes
        // down. These are the conventional shapes — the bar follows the
        // signal, the peak marker hangs behind it long enough to be read.
        inputLevel = max(levels.input, inputLevel * AppModel.meterFall)
        outputLevel = max(levels.output, outputLevel * AppModel.meterFall)
        inputPeak = max(levels.input, inputPeak * AppModel.peakFall)

        if calibrationRemaining > 0 {
            calibrationPeak = max(calibrationPeak, levels.input)
            calibrationRemaining -= 1
            if calibrationRemaining == 0 { finishCalibration() }
        }

        // Once a second, a line in the log saying whether the audio thread is
        // running at all and what it can see. A meter that does not move looks
        // the same whether the callback is idle, the input is silent, or the
        // wrong channels are being read, and only one of those is visible from
        // here.
        meterTicks += 1
        if meterTicks % 30 == 0 {
            engine.logActivity()
        }
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
        // While stopped there is nothing draining the queue; the next start
        // reconciles every slot with the mixer anyway.
        if engine.isRunning {
            engine.soundboard.clear(slot: index)
        }
        saveSettings()
    }

    func playSlot(_ index: Int) {
        guard engine.isRunning, let slot = slots[safe: index] ?? nil else { return }
        engine.soundboard.play(slot: index, gain: slot.volume, loops: slot.loops)
    }

    func stopSlot(_ index: Int) {
        guard engine.isRunning else { return }
        engine.soundboard.stop(slot: index)
    }

    /// Live while dragging. The save is coalesced rather than skipped, because
    /// a slider can also be moved with the keyboard, where there is no drag to
    /// end — but writing the slot list on every frame of a drag is a lot of
    /// encoding for a value that is still moving.
    func setVolume(_ volume: Float, for index: Int) {
        guard var slot = slots[safe: index] ?? nil else { return }
        slot.volume = volume
        slots[index] = slot
        // Applied to the mixer as well as the slot, so dragging the slider is
        // audible on a sample that is already looping. Only while the engine is
        // running: nothing drains the mixer's command queue otherwise, and a
        // full queue silently drops the sample loads that follow it.
        if engine.isRunning {
            engine.soundboard.setGain(volume, at: index)
        }
        scheduleSlotSave()
    }

    func commitSlotEdits() {
        slotSaveTimer?.invalidate()
        slotSaveTimer = nil
        saveSettings()
    }

    private func scheduleSlotSave() {
        slotSaveTimer?.invalidate()
        slotSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commitSlotEdits() }
        }
    }

    func setLoops(_ loops: Bool, for index: Int) {
        guard var slot = slots[safe: index] ?? nil else { return }
        slot.loops = loops
        slots[index] = slot
        saveSettings()
    }

    /// Opens a file picker for a slot. Dropping a file on the slot does the
    /// same thing; this is for people who do not want to go hunting in Finder.
    func chooseFile(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Assign"
        panel.message = "Choose a sound for slot \(index + 1)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        assign(url: url, to: index)
    }

    func stopAllSounds() {
        guard engine.isRunning else { return }
        engine.soundboard.stopAll()
    }

    private func loadSlot(_ index: Int) {
        guard let slot = slots[safe: index] ?? nil else { return }
        do {
            let samples = try SampleLoader.load(slot.fileURL, sampleRate: 48000)
            if engine.soundboard.install(samples, at: index) {
                slotErrors[index] = nil
            } else {
                // The handover queue is full, which means the audio thread has
                // stopped draining it. Saying so beats a tile that looks loaded
                // and plays nothing.
                slotErrors[index] = "Could not hand the sound to the audio engine. Restart it and try again."
            }
        } catch {
            // Surfaced on the slot itself. The audio thread never sees a file
            // that failed to load.
            slotErrors[index] = error.localizedDescription
        }
    }

    /// Brings the mixer in line with the slot list. Called on start, which is
    /// the only moment the two are guaranteed to agree — edits made while the
    /// engine was stopped never reached it.
    private func reloadAllSlots() {
        for index in slots.indices {
            if slots[index] != nil {
                loadSlot(index)
            } else {
                engine.soundboard.clear(slot: index)
                slotErrors[index] = nil
            }
        }
    }

    // MARK: - System audio capture

    /// Apps that are currently playing something, newest listing first.
    func refreshAudioProcesses() {
        audioProcesses = SystemAudioTap.audioProcesses()
            .map { CapturableApp(process: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setCaptured(_ captured: Bool, bundleID: String) {
        if captured {
            capturedBundleIDs.insert(bundleID)
        } else {
            capturedBundleIDs.remove(bundleID)
        }
        saveSettings()
        restartIfRunning()
    }

    /// Bundle identifiers are what gets remembered, because a process object ID
    /// only lasts as long as the app it belongs to. They are resolved back to
    /// live objects here, at the moment the tap is built.
    private var chosenProcessIDs: [AudioObjectID] {
        SystemAudioTap.audioProcesses()
            .filter { capturedBundleIDs.contains($0.bundleID) }
            .map(\.id)
    }

    // MARK: - Hot keys

    func registerHotKeys() {
        hotKeyManager.unregisterAll()
        guard recordingAction == nil else { return }

        var rejected: [String] = []
        for (action, hotKey) in hotKeys {
            if !hotKeyManager.register(hotKey, for: action) {
                rejected.append("\(hotKey.displayName) (\(action.displayName))")
            }
        }
        if !rejected.isEmpty {
            // Carbon refuses a combination another application already holds,
            // and it is the only way to find out.
            statusMessage = "Already taken by another app: \(rejected.sorted().joined(separator: ", "))"
        }
    }

    /// Suspends the global shortcuts so the recorder can see the keys.
    ///
    /// A registered Carbon hot key is swallowed before it reaches the
    /// application, so pressing the key being rebound would fire the action it
    /// is already bound to instead of being recorded.
    func beginRecordingHotKey(for action: HotKeyManager.Action) {
        recordingAction = action
        hotKeyManager.unregisterAll()
    }

    func endRecordingHotKey(for action: HotKeyManager.Action) {
        // A recorder that was already superseded by another must not put the
        // shortcuts back while that other one is still listening.
        guard recordingAction == action else { return }
        recordingAction = nil
        registerHotKeys()
    }

    /// A combination belongs to one action, so assigning it takes it away from
    /// whichever action held it before.
    func assign(_ hotKey: HotKey, to action: HotKeyManager.Action) {
        for (other, existing) in hotKeys where other != action && existing == hotKey {
            hotKeys[other] = nil
        }
        hotKeys[action] = hotKey
        saveSettings()
    }

    /// What the hum remover has found, in words.
    ///
    /// A control that does nothing in a quiet room needs to say so, or it reads
    /// as broken to anyone who turns it up and hears no difference.
    var humDescription: String {
        guard isRunning else {
            return "Notches out electrical buzz from a charger, a cable or an interface. Nothing is removed unless hum is actually found."
        }
        let found = engine.chain.detectedHumHz
        return found > 0
            ? String(format: "Found %.0f Hz hum and its harmonics.", found)
            : "No hum found — nothing is being removed."
    }

    /// The shortcut printed on a soundboard tile, if the slot has one.
    func shortcutName(forSlot index: Int) -> String? {
        guard let action = HotKeyManager.Action(rawValue: "playSlot\(index)") else { return nil }
        return hotKeys[action]?.displayName
    }

    func clearHotKey(for action: HotKeyManager.Action) {
        hotKeys[action] = nil
        saveSettings()
        registerHotKeys()
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
        defaults.set(captureGain, forKey: Keys.captureGain)
        defaults.set(inputTrimDB, forKey: Keys.inputTrim)
        defaults.set(Array(capturedBundleIDs), forKey: Keys.capturedApps)
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
        if defaults.object(forKey: Keys.captureGain) != nil {
            captureGain = defaults.float(forKey: Keys.captureGain)
        }
        if defaults.object(forKey: Keys.inputTrim) != nil {
            inputTrimDB = defaults.float(forKey: Keys.inputTrim)
        }
        if let stored = defaults.stringArray(forKey: Keys.capturedApps) {
            capturedBundleIDs = Set(stored)
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
            // Restored even when empty: a user who cleared every shortcut meant
            // it, and bringing the defaults back at the next launch would look
            // like the app arguing.
            hotKeys = restored
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
