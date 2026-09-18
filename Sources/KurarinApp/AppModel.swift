import Foundation
import AppKit
import os
import CoreAudio
import Combine
import KurarinDSP
import KurarinEngine
import KurarinPresets
import CoreGraphics
import KurarinRecording
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

    /// Whether the message above is something that went wrong.
    ///
    /// Most of what lands here is: a device that vanished, a permission
    /// refused, a microphone that heard nothing. Recording is the exception —
    /// it reports success the same way, and "Saved to Movies" under a warning
    /// triangle reads as a failure at a glance.
    @Published private(set) var statusIsWarning = true

    private func report(_ message: String, warning: Bool = true) {
        statusMessage = message
        statusIsWarning = warning
    }

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
            report("Start the engine before setting the microphone gain.")
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
            report("Heard nothing. Check the microphone and try again.")
            return
        }
        let heardDB = 20 * log10(calibrationPeak)
        guard heardDB > -60 else {
            report("Heard almost nothing — speak while it listens.")
            return
        }

        // The trim is already in the measurement, so the correction is added to
        // it rather than replacing it.
        let corrected = inputTrimDB + (AppModel.targetPeakDB - heardDB)
        inputTrimDB = min(max(corrected, -12), 36)
        report(
            String(
                format: "Microphone gain set to %+.0f dB — your voice peaked at %.0f dB.",
                inputTrimDB, heardDB
            ),
            warning: false
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
    @Published private(set) var outputLevel: Float = 0
    /// Falls far more slowly than the bar, so a peak stays readable.

    /// Polls remaining in a calibration run, and the loudest thing heard so far.
    @Published private(set) var calibrationRemaining = 0
    private var calibrationPeak: Float = 0

    /// Where a speaking voice should peak. Loud enough to sit well above the
    /// noise floor and the gate, with room left for a shout before the limiter
    /// has to do anything about it.
    static let targetPeakDB: Float = -12
    static let comfortableRangeDB: ClosedRange<Float> = -18 ... -6

    /// Published separately: see `Meters`.
    let meters = Meters()

    /// Whether the settings window is on screen.
    ///
    /// A menu bar app spends most of its life with no window at all, and
    /// driving the interface at meter rate for nobody is the difference
    /// between idling and being killed for using half a core.
    var isSettingsVisible = false


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
            report("\(reason). Switched to the system default.")
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
            report(AudioDeviceError.driverNotInstalled.localizedDescription)
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
            if let failure = engine.captureFailure { report(failure) }

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
            report(error.localizedDescription)
            appLog.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        meters.clear()

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
        stopRecordingIfEngineStopped()
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
        // Before the guard: this is something the user goes and does while the
        // engine is stopped, and the interface has to notice when they come
        // back rather than only after they press Start.
        refreshRecordingPermission()

        guard isRunning else {
            if isInputClipping { isInputClipping = false }
            meters.clear()
            return
        }

        let levels = engine.drainLevels()

        // Only while somebody is looking. The engine still has to be drained —
        // its peaks accumulate until they are read — but turning those numbers
        // into published state with no window on screen is the whole of what
        // was tripping the CPU limit.
        if isSettingsVisible {
            meters.update(input: levels.input, output: levels.output)
        }

        updateClippingWarning()

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
            report(error.localizedDescription)
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
            report("Already taken by another app: \(rejected.sorted().joined(separator: ", "))")
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

    /// What the pitch target is actually doing, or nil when there is nothing
    /// to report.
    ///
    /// Same reasoning as `humDescription`, and more pressing here. This
    /// control works by learning where the speaker's voice rests, which takes
    /// a couple of seconds of speech before it does anything at all — so
    /// somebody who switches it on and hears nothing change has no way to tell
    /// waiting from broken.
    ///
    /// It also cannot always do what it is asked. The shifter is bounded to an
    /// octave either way, so a deep voice aimed at the top of the range lands
    /// short, and silently landing short is the worst of the three outcomes to
    /// leave unexplained.
    var pitchDescription: String? {
        let target = editedParameters.targetPitchHz
        guard target > 0, isRunning, isEffectEnabled else { return nil }

        let heard = engine.chain.detectedPitchHz
        guard heard > 0 else { return "Listening — say a few words and it will find your voice." }

        // Derived from what was heard rather than read back from the shifter:
        // the chain sets the speaker's pitch on the first voiced block and the
        // ratio only on the next one, so reading the ratio there would claim
        // the target was out of range for as long as that gap lasts.
        let landing = VoiceChain.landingPitch(heard: heard, target: target)
        guard abs(landing - target) > 2 else {
            return String(format: "Hearing you around %.0f Hz, landing on %.0f Hz.", heard, landing)
        }
        return String(
            format: "Hearing you around %.0f Hz. %.0f Hz is more than an octave away, so it lands at %.0f Hz.",
            heard, target, landing
        )
    }

    /// Whether the microphone is arriving already clipped.
    ///
    /// This is the one fault in the signal path that gets worse the harder the
    /// rest of the app works: the shifter lays each glottal period down several
    /// times over, so a flattened waveform is repeated rather than averaged
    /// away, and a voice that merely sounded loud going in comes out sounding
    /// broken. No gain of ours can put back what the converter threw away.
    @Published private(set) var isInputClipping = false

    private var lastClippedCount = 0
    private var clippingHoldTicks = 0

    /// Held for a couple of seconds after the last clipped sample, because
    /// clipping happens on syllables and a warning that blinks at syllable rate
    /// is unreadable.
    /// A recording with no sound coming in is worse than no recording, so the
    /// two stop together.
    private func stopRecordingIfEngineStopped() {
        guard isRecording, !isRunning else { return }
        Task { await finishRecording() }
    }

    private func updateClippingWarning() {
        let count = engine.clippedInputSamples
        if count > lastClippedCount {
            clippingHoldTicks = 60
        } else if clippingHoldTicks > 0 {
            clippingHoldTicks -= 1
        }
        lastClippedCount = count

        let clipping = clippingHoldTicks > 0
        if clipping != isInputClipping { isInputClipping = clipping }
    }

    // MARK: - Screen recording

    @Published private(set) var isRecording = false
    @Published private(set) var recordingURL: URL?

    private lazy var recorder = ScreenRecorder(audio: engine.recordingAudio)

    /// Recording captures the engine's own mix rather than the system's sound.
    ///
    /// What a listener hears never reaches the speakers — it goes to the
    /// virtual microphone — so asking the screen recorder for system audio
    /// would capture the wrong thing. The engine hands its finished mix over
    /// instead, which also means the recording holds exactly what was sent,
    /// including the soundboard and the transformed voice, and none of the
    /// monitoring.
    func toggleRecording() {
        if isRecording {
            Task { await finishRecording() }
        } else {
            Task { await beginRecording() }
        }
    }

    private func beginRecording() async {
        guard isRunning else {
            report("Start Kurarin first — there is no sound to record until it is running.")
            return
        }

        let directory = recordingFolder
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = directory.appendingPathComponent("Kurarin \(stamp.string(from: Date())).mov")

        do {
            engine.isCapturingForRecording = true
            try await recorder.start(to: url)
            recordingNeedsPermission = false
            isRecording = true
            recordingURL = url
            report("Recording to \(url.lastPathComponent).", warning: false)
        } catch {
            engine.isCapturingForRecording = false
            recordingNeedsPermission = error is RecordingError
            report(error.localizedDescription)
        }
    }

    private func finishRecording() async {
        engine.isCapturingForRecording = false
        await recorder.stop()
        isRecording = false

        if let failure = recorder.failure {
            recordingURL = nil
            report(failure.localizedDescription)
            return
        }

        // Says which of the two silences it was, if the recording is quiet:
        // nothing playing, or the capture not working.
        if recorder.systemSamplesSeen == 0 {
            report("Recorded, but macOS sent no system audio — the computer's own sound will be missing.")
        }

        let lost = recorder.droppedSamples
        if let url = recordingURL {
            if lost > 0 {
                report(String(
                    format: "Saved %@ — %.0f ms of sound was lost to a slow disk.",
                    url.lastPathComponent, Double(lost) / 48.0
                ))
            } else {
                report("Saved \(url.lastPathComponent) to Movies.", warning: false)
            }
        }
    }

    /// macOS only offers the permission dialog once, and never at all for an
    /// app it has not seen signed the same way twice — which is every build of
    /// an ad-hoc signed one. Sending the user straight to the right pane is
    /// more use than telling them where it is.
    func openScreenRecordingSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether macOS will let us record at all, checked rather than discovered
    /// by failing.
    ///
    /// Worth showing before the button is pressed. The permission cannot be
    /// asked for twice — macOS remembers the first answer, and for an app it
    /// has not seen signed the same way before it declines to ask at all — so
    /// somebody who has not granted it needs telling that, not a button that
    /// looks like it works.
    @Published private(set) var recordingNeedsPermission = false

    /// Where recordings go. Shown so the answer is visible before there is
    /// anything in it, which is when people look.
    var recordingFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func revealRecordingFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recordingFolder.path)
    }

    /// Cheap enough to run on the meter timer, but not thirty times a second.
    private func refreshRecordingPermission() {
        permissionTicks += 1
        guard permissionTicks % 30 == 0 else { return }
        let needed = !CGPreflightScreenCaptureAccess()
        if needed != recordingNeedsPermission { recordingNeedsPermission = needed }
    }

    private var permissionTicks = 0

    /// Used when the app is going away and there is no interface left to tell.
    ///
    /// Synchronous on purpose: the caller is `applicationWillTerminate`, which
    /// runs on the main thread, and anything that waits there for main-actor
    /// work to complete waits for itself.
    func finishRecordingForQuit() {
        guard isRecording else { return }
        engine.isCapturingForRecording = false
        recorder.finishSynchronously()
        isRecording = false
    }

    func revealRecording() {
        guard let recordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
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
        case .toggleRecording: toggleRecording()
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
