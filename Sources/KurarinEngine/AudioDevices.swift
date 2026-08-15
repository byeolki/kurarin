import Foundation
import CoreAudio

public struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public var canRecord: Bool { inputChannels > 0 }
    public var canPlay: Bool { outputChannels > 0 }
}

public enum AudioDeviceError: Error, LocalizedError {
    case coreAudio(OSStatus, String)
    case driverNotInstalled
    case deviceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let status, let context):
            return "\(context) failed (Core Audio status \(status))."
        case .driverNotInstalled:
            return "The Kurarin virtual microphone is not installed. Run sudo ./scripts/install-driver.sh."
        case .deviceUnavailable(let name):
            return "\(name) is no longer available."
        }
    }
}

/// Thin wrapper over the Core Audio property API.
///
/// Every call is four lines of address struct, size query and pointer dance.
/// Collecting that here keeps the routing code readable and gives one place to
/// get the scope and element conventions right.
public enum AudioDevices {
    /// UID of the device the driver publishes. Must match KurarinDriver.c.
    public static let virtualDeviceUID = "com.byeolki.kurarin.microphone"

    /// Prefix of the UIDs given to the engine's own aggregate devices. Private
    /// aggregates are hidden from other applications but not from the process
    /// that created them, so they have to be filtered out here or the engine's
    /// own routing device turns up in the user's device pickers.
    public static let aggregateUIDPrefix = "com.byeolki.kurarin.aggregate."

    /// Devices Kurarin owns are never something for the user to select: routing
    /// the engine's output back into its input is a feedback loop, and the
    /// aggregate exists only for the lifetime of a session.
    static func isOwnDevice(_ uid: String) -> Bool {
        uid == virtualDeviceUID || uid.hasPrefix(aggregateUIDPrefix)
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func dataSize(
        of object: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> UInt32? {
        var size: UInt32 = 0
        var addressCopy = address
        let status = AudioObjectGetPropertyDataSize(object, &addressCopy, 0, nil, &size)
        return status == noErr ? size : nil
    }

    /// Constrained to trivial types: Core Audio writes raw bytes into the
    /// destination, which is only meaningful for a value with no references.
    static func value<T: BitwiseCopyable>(
        of object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        default fallback: T
    ) -> T {
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        var addressCopy = address
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(object, &addressCopy, 0, nil, &size, pointer)
        }
        return status == noErr ? result : fallback
    }

    static func string(
        of object: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> String? {
        var result: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addressCopy = address
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(object, &addressCopy, 0, nil, &size, pointer)
        }
        return status == noErr ? (result as String) : nil
    }

    static func channelCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let size = dataSize(of: device, address), size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        var addressCopy = address
        var sizeCopy = size
        guard AudioObjectGetPropertyData(device, &addressCopy, 0, nil, &sizeCopy, raw) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func allDevices() -> [AudioDeviceInfo] {
        let listAddress = address(kAudioHardwarePropertyDevices)
        guard let size = dataSize(of: AudioObjectID(kAudioObjectSystemObject), listAddress) else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        var addressCopy = listAddress
        var sizeCopy = size
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addressCopy, 0, nil, &sizeCopy, &ids
        )
        guard status == noErr else { return [] }

        return ids.compactMap { id in
            guard let uid = string(of: id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
            let name = string(of: id, address(kAudioObjectPropertyName)) ?? uid
            return AudioDeviceInfo(
                id: id,
                uid: uid,
                name: name,
                inputChannels: channelCount(of: id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(of: id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
    }

    public static func inputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { $0.canRecord && !isOwnDevice($0.uid) }
    }

    public static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { $0.canPlay && !isOwnDevice($0.uid) }
    }

    public static func virtualDevice() -> AudioDeviceInfo? {
        allDevices().first { $0.uid == virtualDeviceUID }
    }

    public static var isDriverInstalled: Bool { virtualDevice() != nil }

    /// The system's input device exactly as it is set, Kurarin's own included.
    ///
    /// `defaultInputDevice()` deliberately looks past our devices, which is the
    /// right answer for "what should the engine listen to" and the wrong one for
    /// "has the takeover already happened".
    public static func systemDefaultInputUID() -> String? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioObjectID(0)
        )
        return allDevices().first { $0.id == id }?.uid
    }

    /// The system's input device, unless that is one of ours.
    ///
    /// Kurarin makes itself the default input on request, so by the time
    /// anything asks this question the answer may well be the virtual device —
    /// and feeding that back into the engine as a microphone is a loop. The
    /// first real input device is a better answer than a broken one.
    public static func defaultInputDevice() -> AudioDeviceInfo? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioObjectID(0)
        )
        let devices = allDevices()
        if let device = devices.first(where: { $0.id == id }), !isOwnDevice(device.uid) {
            return device
        }
        return devices.first { $0.canRecord && !isOwnDevice($0.uid) }
    }

    public static func defaultOutputDevice() -> AudioDeviceInfo? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(0)
        )
        let devices = allDevices()
        if let device = devices.first(where: { $0.id == id }), !isOwnDevice(device.uid) {
            return device
        }
        return devices.first { $0.canPlay && !isOwnDevice($0.uid) }
    }

    /// Points the system's default input at a device.
    ///
    /// Roblox and some other clients offer no microphone picker and simply
    /// follow the system default, so this is the only way to reach them.
    @discardableResult
    public static func setDefaultInputDevice(_ device: AudioDeviceInfo) -> Bool {
        var id = device.id
        var addressCopy = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addressCopy,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &id
        )
        return status == noErr
    }

    /// Makes this process visible to the HAL as an audio client.
    ///
    /// Core Audio creates a process object the first time a process actually
    /// does I/O, so a freshly launched app has none — and a tap that wants to
    /// exclude that process has nothing to name. Briefly running an empty
    /// callback is the cheapest way to exist. Silence is written explicitly
    /// because an output buffer arrives uninitialised.
    static func announceProcessToHAL() {
        guard let device = virtualDevice() ?? defaultOutputDevice() else { return }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) {
            _, _, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
        guard status == noErr, let procID else { return }

        if AudioDeviceStart(device.id, procID) == noErr {
            // Long enough for a callback to have run on any sane buffer size.
            usleep(50_000)
            AudioDeviceStop(device.id, procID)
        }
        AudioDeviceDestroyIOProcID(device.id, procID)
    }

    /// Watches the machine's device list.
    ///
    /// A USB microphone can be unplugged mid-call, and the aggregate device
    /// built on top of it dies with it. Without this the engine would keep
    /// running against a device that no longer exists and simply go quiet.
    public final class Observer {
        private let address = AudioDevices.address(kAudioHardwarePropertyDevices)
        private let listener: AudioObjectPropertyListenerBlock

        public init(onChange: @escaping @Sendable () -> Void) {
            listener = { _, _ in onChange() }
            var addressCopy = address
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addressCopy,
                DispatchQueue.main,
                listener
            )
        }

        deinit {
            var addressCopy = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addressCopy,
                DispatchQueue.main,
                listener
            )
        }
    }

    public static func nominalSampleRate(of device: AudioObjectID) -> Double {
        Double(value(of: device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(48000)))
    }
}
