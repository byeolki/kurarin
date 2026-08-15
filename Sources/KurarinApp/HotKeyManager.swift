import Foundation
import Carbon.HIToolbox
import AppKit

public struct HotKey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayName: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(HotKey.keyName(for: keyCode))
        return parts.joined()
    }

    private static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            49: "Space", 53: "Esc", 48: "Tab", 36: "Return", 51: "Delete", 117: "Fwd Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
            43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }

    /// Builds a hot key from a recorded key press.
    ///
    /// Returns nil for a bare character key: a global shortcut with no
    /// modifiers swallows that key in every application, so typing the letter
    /// anywhere on the system would stop working. Function keys are exempt —
    /// they are the ones worth pressing mid-game, and nothing types with them.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option)  { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

        let keyCode = UInt32(event.keyCode)
        guard carbonModifiers != 0 || HotKey.functionKeyCodes.contains(keyCode) else { return nil }

        self.init(keyCode: keyCode, modifiers: carbonModifiers)
    }
}

/// Registers system-wide keyboard shortcuts.
///
/// Carbon's RegisterEventHotKey rather than an NSEvent global monitor: it needs
/// no accessibility permission, and it works while a game holds the keyboard,
/// which is the entire point of these shortcuts.
/// Marked unchecked because Carbon hands the manager back to us through an
/// opaque context pointer, which strict concurrency cannot reason about. Every
/// member is only ever touched on the main thread.
public final class HotKeyManager: @unchecked Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case toggleMute
        case toggleEffect
        case nextPreset
        case previousPreset
        case stopSoundboard
        case playSlot0, playSlot1, playSlot2, playSlot3, playSlot4, playSlot5
        case playSlot6, playSlot7, playSlot8, playSlot9, playSlot10, playSlot11

        public var displayName: String {
            switch self {
            case .toggleMute:      return "Mute microphone"
            case .toggleEffect:    return "Toggle voice effect"
            case .nextPreset:      return "Next preset"
            case .previousPreset:  return "Previous preset"
            case .stopSoundboard:  return "Stop all sounds"
            default:               return "Play slot \(slotIndex.map { $0 + 1 } ?? 0)"
            }
        }

        public var slotIndex: Int? {
            guard rawValue.hasPrefix("playSlot") else { return nil }
            return Int(rawValue.dropFirst("playSlot".count))
        }
    }

    /// Invoked on the main thread. Carbon dispatches hot key events on the
    /// main run loop, so the isolation below is an assertion of what already
    /// holds rather than a hop.
    public var handler: (@MainActor (Action) -> Void)?

    private var registrations: [Action: EventHotKeyRef] = [:]
    private var identifiers: [UInt32: Action] = [:]
    /// Keys currently held down. A held hot key repeats, and a repeating mute
    /// toggle flaps the microphone open and shut for as long as the finger
    /// stays there.
    private var heldActions: Set<Action> = []
    /// When each action was last seen, so a lost release cannot wedge a
    /// shortcut off for the session. Key repeat arrives far faster than this
    /// gap, so holding a key still never fires twice.
    private var lastEventTime: [Action: TimeInterval] = [:]
    private static let repeatGap: TimeInterval = 0.5
    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    public init() {
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() {
        // Releases are watched only to know when a key stops being held.
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier
            )
            guard status == noErr, let action = manager.identifiers[identifier.id] else {
                return noErr
            }

            let now = Foundation.ProcessInfo.processInfo.systemUptime
            let previous = manager.lastEventTime[action]
            manager.lastEventTime[action] = now

            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                manager.heldActions.remove(action)
                return noErr
            }

            // One action per press, however long the key is held — unless the
            // gap since the last event is longer than any key repeat, which
            // means the release went missing and this really is a new press.
            let isRepeat = manager.heldActions.contains(action)
                && now - (previous ?? 0) < HotKeyManager.repeatGap
            manager.heldActions.insert(action)
            guard !isRepeat else { return noErr }

            MainActor.assumeIsolated { manager.handler?(action) }
            return noErr
        }, specs.count, &specs, context, &eventHandler)
    }

    @discardableResult
    public func register(_ hotKey: HotKey, for action: Action) -> Bool {
        unregister(action)

        let identifier = nextIdentifier
        nextIdentifier += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B555241), id: identifier) // 'KURA'
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else { return false }
        registrations[action] = reference
        identifiers[identifier] = action
        return true
    }

    public func unregister(_ action: Action) {
        guard let reference = registrations.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(reference)
        identifiers = identifiers.filter { $0.value != action }
        // Its release will never arrive now, so the held state has to go with it.
        heldActions.remove(action)
    }

    public func unregisterAll() {
        for action in registrations.keys { unregister(action) }
    }

    public static let defaults: [Action: HotKey] = [
        .toggleMute:   HotKey(keyCode: 122, modifiers: 0),                       // F1
        .toggleEffect: HotKey(keyCode: 120, modifiers: 0),                       // F2
        .previousPreset: HotKey(keyCode: 99, modifiers: 0),                      // F3
        .nextPreset:   HotKey(keyCode: 118, modifiers: 0),                       // F4
        .stopSoundboard: HotKey(keyCode: 96, modifiers: 0),                      // F5
    ]
}
