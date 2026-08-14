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
        // The virtual device is excluded as an input: selecting it would feed
        // the engine's own output back into itself.
        allDevices().filter { $0.canRecord && $0.uid != virtualDeviceUID }
    }

    public static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { $0.canPlay && $0.uid != virtualDeviceUID }
    }

    public static func virtualDevice() -> AudioDeviceInfo? {
        allDevices().first { $0.uid == virtualDeviceUID }
    }

    public static var isDriverInstalled: Bool { virtualDevice() != nil }

    public static func defaultInputDevice() -> AudioDeviceInfo? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioObjectID(0)
        )
        return allDevices().first { $0.id == id }
    }

    public static func defaultOutputDevice() -> AudioDeviceInfo? {
        let id = value(
            of: AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(0)
        )
        return allDevices().first { $0.id == id }
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

    public static func nominalSampleRate(of device: AudioObjectID) -> Double {
        Double(value(of: device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(48000)))
    }
}
