import Foundation
import CoreAudio
import AVFoundation

/// A private aggregate device tying the microphone, the virtual device, the
/// monitoring output and the system audio tap into one clock domain.
///
/// Separate audio devices run on separate clocks. Bridge them with your own
/// ring buffer and the two ends drift apart, so a few minutes in the audio
/// starts ticking and dropping out — and drift bugs are miserable to reproduce.
/// An aggregate hands that problem to Core Audio, which resamples against a
/// designated master clock in hardware-aware ways nothing in userspace can
/// match.
///
/// The aggregate is marked private, so it never shows up in Audio MIDI Setup or
/// in any other application's device list, and it disappears when the app
/// exits. Users never have to build or maintain a routing device by hand.
public final class AggregateDevice {
    public struct Layout {
        /// Channel offsets into the aggregate's interleaved input buffer.
        public var microphoneInputOffset: Int = 0
        public var microphoneChannels: Int = 0
        public var tapInputOffset: Int = 0
        public var tapChannels: Int = 0

        /// Channel offsets into the aggregate's output buffer.
        public var virtualOutputOffset: Int = 0
        public var virtualChannels: Int = 0
        public var monitorOutputOffset: Int = 0
        public var monitorChannels: Int = 0
    }

    public private(set) var deviceID: AudioObjectID = 0
    public private(set) var layout = Layout()
    public let sampleRate: Double

    private var tapID: AudioObjectID = 0
    private let tapUID: String?

    /// - Parameters:
    ///   - microphone: input device, and the aggregate's master clock
    ///   - monitor: where the user hears the soundboard and, optionally, themselves
    ///   - tap: an already-created system audio tap, or nil
    public init(
        microphone: AudioDeviceInfo,
        virtualDevice: AudioDeviceInfo,
        monitor: AudioDeviceInfo?,
        tap: SystemAudioTap?,
        sampleRate: Double = 48000
    ) throws {
        self.sampleRate = sampleRate
        self.tapUID = tap?.uid
        self.tapID = tap?.objectID ?? 0

        // Order here is the channel order in the aggregate's buffers, so the
        // offsets computed below have to follow the same sequence.
        var subDeviceUIDs: [String] = [microphone.uid, virtualDevice.uid]
        if let monitor, monitor.uid != microphone.uid, monitor.uid != virtualDevice.uid {
            subDeviceUIDs.append(monitor.uid)
        }

        var subDevices: [[String: Any]] = []
        for uid in subDeviceUIDs {
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: uid]
            if uid != microphone.uid {
                // The master clock needs no correction; everything else does.
                entry[kAudioSubDeviceDriftCompensationKey] = 1
                entry[kAudioSubDeviceDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationMaxQuality
            }
            subDevices.append(entry)
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kurarin Engine",
            kAudioAggregateDeviceUIDKey: AudioDevices.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: microphone.uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]

        if let tapUID {
            description[kAudioAggregateDeviceTapAutoStartKey] = 1
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: 1,
            ]]
        }

        var created: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &created)
        guard status == noErr, created != 0 else {
            throw AudioDeviceError.coreAudio(status, "Creating the aggregate device")
        }
        deviceID = created

        layout = AggregateDevice.computeLayout(
            microphone: microphone,
            virtualDevice: virtualDevice,
            monitor: subDeviceUIDs.count > 2 ? monitor : nil,
            tapChannels: tap != nil ? 2 : 0
        )
    }

    deinit {
        destroy()
    }

    public func destroy() {
        if deviceID != 0 {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    /// Channels appear in the order the sub-devices were listed, with tap
    /// channels appended after them.
    private static func computeLayout(
        microphone: AudioDeviceInfo,
        virtualDevice: AudioDeviceInfo,
        monitor: AudioDeviceInfo?,
        tapChannels: Int
    ) -> Layout {
        var layout = Layout()

        var inputCursor = 0
        layout.microphoneInputOffset = inputCursor
        layout.microphoneChannels = microphone.inputChannels
        inputCursor += microphone.inputChannels

        inputCursor += virtualDevice.inputChannels
        inputCursor += monitor?.inputChannels ?? 0

        layout.tapInputOffset = inputCursor
        layout.tapChannels = tapChannels

        var outputCursor = 0
        outputCursor += microphone.outputChannels

        layout.virtualOutputOffset = outputCursor
        layout.virtualChannels = virtualDevice.outputChannels
        outputCursor += virtualDevice.outputChannels

        if let monitor {
            layout.monitorOutputOffset = outputCursor
            layout.monitorChannels = monitor.outputChannels
        }

        return layout
    }
}

/// A Core Audio process tap over system audio.
///
/// The tap is non-destructive: it copies what other applications are playing
/// without taking it away from them. That is what makes sharing music work
/// without the usual multi-output device contortions, where the sound
/// disappears from your own headphones and the volume keys stop working.
public final class SystemAudioTap {
    public enum Source {
        /// Everything on the machine, minus this process.
        case entireSystem
        /// Only the listed audio processes.
        case processes([AudioObjectID])
    }

    public let objectID: AudioObjectID
    public let uid: String

    public init(source: Source) throws {
        let description: CATapDescription
        switch source {
        case .entireSystem:
            // Excluding ourselves is not optional: what the engine writes to the
            // virtual device would otherwise be captured and mixed back into the
            // virtual device, one block later, forever.
            //
            // The exclusion list holds audio object IDs, not process IDs, and
            // the two are not interchangeable — passing a pid here silently
            // excludes nothing, or the wrong process.
            let excluded = SystemAudioTap.ownProcessObjects()
            guard !excluded.isEmpty else {
                // Refusing to build the tap costs the capture feature. Building
                // one that excludes nothing costs the whole session.
                throw AudioDeviceError.selfExclusionUnavailable
            }
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: excluded
            )
        case .processes(let objects):
            description = CATapDescription(
                stereoMixdownOfProcesses: objects
            )
        }

        let identifier = UUID()
        description.uuid = identifier
        description.name = "Kurarin System Audio"
        // Leave the captured applications audible; muting them is what the old
        // routing tricks did wrong.
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var created: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &created)
        guard status == noErr, created != 0 else {
            throw AudioDeviceError.coreAudio(status, "Creating the system audio tap")
        }

        objectID = created
        uid = identifier.uuidString
    }

    /// This process, as Core Audio addresses it.
    ///
    /// The HAL only has an object for a process once that process has touched
    /// audio, and a tap can be built before the engine's first callback has
    /// run. When the lookup comes up empty the engine is asked to make itself
    /// known and it is tried again, because a global tap that fails to exclude
    /// Kurarin is a feedback loop rather than a missing feature.
    static func ownProcessObjects() -> [AudioObjectID] {
        if let object = processObject(for: getpid()) { return [object] }
        AudioDevices.announceProcessToHAL()
        return processObject(for: getpid()).map { [$0] } ?? []
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = AudioDevices.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        return status == noErr && object != 0 ? object : nil
    }

    /// One process Core Audio knows about, as the tap API addresses it.
    public struct ProcessInfo: Identifiable, Equatable, Sendable {
        /// Audio object ID — this, not the pid, is what a tap description takes.
        public let id: AudioObjectID
        public let pid: pid_t
        public let bundleID: String
    }

    /// Every process Core Audio currently accounts for, minus this one.
    ///
    /// Kurarin excludes itself unconditionally: capturing our own monitoring
    /// output would feed the mix straight back into itself.
    public static func audioProcesses() -> [ProcessInfo] {
        let address = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        guard let size = AudioDevices.dataSize(of: AudioObjectID(kAudioObjectSystemObject), address) else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        var addressCopy = address
        var sizeCopy = size
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addressCopy, 0, nil, &sizeCopy, &ids
        ) == noErr else {
            return []
        }

        let ownPID = getpid()
        return ids.compactMap { id in
            guard let bundleID = AudioDevices.string(
                of: id,
                AudioDevices.address(kAudioProcessPropertyBundleID)
            ), !bundleID.isEmpty else {
                return nil
            }
            let pid = AudioDevices.value(
                of: id,
                AudioDevices.address(kAudioProcessPropertyPID),
                default: pid_t(-1)
            )
            guard pid != ownPID else { return nil }
            return ProcessInfo(id: id, pid: pid, bundleID: bundleID)
        }
    }
}
