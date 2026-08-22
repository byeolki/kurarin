import AppKit
import Combine
import SwiftUI

/// The menu bar item, and the window it opens.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` for one reason: a
/// `MenuBarExtra` always opens its menu, and there is no way to tell it that a
/// plain click should do something else. Settings is what you want almost every
/// time you reach for this icon — the quick toggles are on shortcut keys — so a
/// left click opens it and the menu moves to the right button, which is where
/// macOS puts secondary actions anyway.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private var settingsWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            // Without this the button only reports the left button, and the
            // right one falls through to nothing.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()

        // The icon carries the only state visible while a game has focus:
        // whether it is running, and whether it is muted.
        model.$isRunning.sink { [weak self] _ in self?.scheduleIconUpdate() }.store(in: &observers)
        model.$isMuted.sink { [weak self] _ in self?.scheduleIconUpdate() }.store(in: &observers)
        model.$isRecording.sink { [weak self] _ in self?.scheduleIconUpdate() }.store(in: &observers)
    }

    private func scheduleIconUpdate() {
        // The publishers fire before the property is assigned, so read it back
        // on the next turn of the loop rather than from the value handed over.
        DispatchQueue.main.async { [weak self] in self?.updateIcon() }
    }

    private func updateIcon() {
        // Recording wins over everything else the icon could say. Leaving a
        // recording running by accident is the expensive mistake here.
        let name = model.isRecording
            ? "record.circle"
            : model.isRunning
                ? (model.isMuted ? "mic.slash.fill" : "waveform")
                : "waveform.slash"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Kurarin")
    }

    @objc private func clicked() {
        let rightButton = NSApp.currentEvent?.type == .rightMouseUp
        let controlHeld = NSApp.currentEvent?.modifierFlags.contains(.control) ?? false
        if rightButton || controlHeld {
            showMenu()
        } else {
            showSettings()
        }
    }

    // MARK: - Settings window

    /// Built once and reused. A menu bar app that makes a new window every time
    /// leaves the old one's state behind and stacks them up off-screen.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Kurarin"
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("KurarinSettings")
            window.contentView = NSHostingView(
                rootView: MainWindow().environmentObject(model).frame(minWidth: 620, minHeight: 460)
            )
            window.contentMinSize = NSSize(width: 620, height: 460)
            settingsWindow = window
        }

        // An agent app is not frontmost by default, so the window would open
        // behind whatever the user was looking at without this.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu

    private func showMenu() {
        guard let button = item.button else { return }
        // Popped up directly rather than by handing the menu to the status item
        // and clicking it again. Assigning `item.menu` makes every click open
        // the menu, which is the behaviour this class exists to avoid, and
        // calling performClick from inside the button's own action re-enters it.
        buildMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        add(to: menu, model.isRunning ? "Stop" : "Start", #selector(toggleRunning))

        if model.isRunning {
            add(to: menu, "Mute microphone", #selector(toggleMute), on: model.isMuted)
            add(to: menu, "Voice effect", #selector(toggleEffect), on: model.isEffectEnabled)
            add(to: menu, "Hear myself", #selector(toggleMonitor), on: model.monitorVoice)
        }

        menu.addItem(.separator())

        let presets = NSMenu()
        for (index, preset) in model.presets.enumerated() {
            let entry = NSMenuItem(title: preset.name, action: #selector(choosePreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = preset.id == model.selectedPresetID ? .on : .off
            presets.addItem(entry)
        }
        let presetItem = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        presetItem.submenu = presets
        menu.addItem(presetItem)

        let filled = model.slots.enumerated().compactMap { index, slot in slot.map { (index, $0) } }
        if !filled.isEmpty {
            let sounds = NSMenu()
            for (index, slot) in filled {
                let entry = NSMenuItem(title: slot.name, action: #selector(playSlot(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                sounds.addItem(entry)
            }
            sounds.addItem(.separator())
            let stop = NSMenuItem(title: "Stop all sounds", action: #selector(stopSounds), keyEquivalent: "")
            stop.target = self
            sounds.addItem(stop)

            let soundItem = NSMenuItem(title: "Soundboard", action: nil, keyEquivalent: "")
            soundItem.submenu = sounds
            menu.addItem(soundItem)
        }

        menu.addItem(.separator())
        if model.isRunning || model.isRecording {
            add(to: menu, model.isRecording ? "Stop recording" : "Record screen",
                #selector(toggleRecording), on: model.isRecording)
        }
        add(to: menu, "Settings…", #selector(openSettings))
        let quit = NSMenuItem(title: "Quit Kurarin", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = on ? .on : .off
        menu.addItem(entry)
    }

    // MARK: - Actions

    @objc private func toggleRunning() { model.toggleRunning() }
    @objc private func toggleMute() { model.isMuted.toggle() }
    @objc private func toggleEffect() { model.isEffectEnabled.toggle() }
    @objc private func toggleMonitor() { model.monitorVoice.toggle() }
    @objc private func stopSounds() { model.stopAllSounds() }
    @objc private func openSettings() { showSettings() }
    @objc private func toggleRecording() { model.toggleRecording() }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        guard model.presets.indices.contains(sender.tag) else { return }
        model.selectPreset(model.presets[sender.tag])
    }

    @objc private func playSlot(_ sender: NSMenuItem) {
        model.playSlot(sender.tag)
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }
}
