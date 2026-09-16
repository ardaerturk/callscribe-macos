import AudioToolbox
import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public var uid: String { id }

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Snapshot policy is separate from Core Audio reads so route-change cases can
/// be tested without opening an input or changing the user's audio devices.
struct InputDeviceCandidate {
    let objectID: AudioObjectID
    let device: AudioInputDevice
    let transport: UInt32
    var hidden: Bool = false

    var isSelectable: Bool {
        !hidden && !device.uid.hasPrefix("CADefaultDeviceAggregate-")
            && !device.name.hasPrefix("CADefaultDeviceAggregate-")
            && !device.uid.hasPrefix("app.callscribe.capture.")
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isPhysicalAlternative: Bool {
        [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
         kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
         kAudioDeviceTransportTypeThunderbolt].contains(transport)
    }
}

enum CoreAudioDeviceCatalog {
    static func selectInput(uid: String?, candidates: [InputDeviceCandidate]) throws -> InputDeviceCandidate {
        let available = candidates.filter(\.isSelectable)
        if let uid, !uid.isEmpty {
            guard let selected = available.first(where: { $0.device.uid == uid }) else {
                throw CallScribeCoreError.inputDeviceUnavailable(uid)
            }
            return selected
        }
        // Do not substitute a virtual/aggregate device just because its transport
        // isn't Bluetooth. AVAudioEngine exposes transient aggregates here too.
        let physical = available.first(where: \.isPhysicalAlternative)
        if let current = available.first(where: { $0.device.isDefault }) {
            return current.isBluetooth ? (physical ?? current) : current
        }
        if let fallback = physical ?? available.first(where: \.isBluetooth) {
            return fallback
        }
        throw CallScribeCoreError.inputDeviceUnavailable("default input")
    }

    static func inputDevices() throws -> [AudioInputDevice] {
        try inputCandidates().filter(\.isSelectable).map(\.device).sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func inputCandidates() throws -> [InputDeviceCandidate] {
        let devices: [AudioObjectID] = try AudioObjectID.system.readArray(
            selector: kAudioHardwarePropertyDevices
        )
        let defaultDevice: AudioObjectID = (try? AudioObjectID.system.readValue(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: kAudioObjectUnknown
        )) ?? kAudioObjectUnknown

        return devices.compactMap { deviceID in
            // A device can disappear between enumeration and property reads.
            // That must not hide every other available microphone.
            guard let count = try? deviceID.inputChannelCount(), count > 0,
                  let uid = try? deviceID.readString(selector: kAudioDevicePropertyDeviceUID),
                  let name = try? deviceID.readString(selector: kAudioObjectPropertyName) else { return nil }
            let transport: UInt32 = (try? deviceID.readValue(selector: kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
            let hidden: UInt32 = (try? deviceID.readValue(selector: kAudioDevicePropertyIsHidden, defaultValue: UInt32(0))) ?? 0
            return InputDeviceCandidate(objectID: deviceID,
                device: AudioInputDevice(id: uid, name: name, isDefault: deviceID == defaultDevice),
                transport: transport, hidden: hidden != 0)
        }
    }

    static func resolveInputDevice(uid: String?) throws -> (AudioObjectID, AudioInputDevice) {
        let selected = try selectInput(uid: uid, candidates: inputCandidates())
        return (selected.objectID, selected.device)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func readValue<T>(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read Core Audio property", status: status)
        }
        return value
    }

    func readArray<T>(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read Core Audio property size", status: status)
        }
        guard size > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { _, count in
            count = Int(size) / MemoryLayout<T>.stride
        }
        status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read Core Audio array property", status: status)
        }
        return values
    }

    func readString(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read Core Audio string property", status: status)
        }
        return value.takeRetainedValue() as String
    }

    func translateDeviceUID(_ uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var result = kAudioObjectUnknown
        var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                self,
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &resultSize,
                &result
            )
        }
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Resolve input device UID", status: status)
        }
        return result
    }

    func translateProcessID(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var result = kAudioObjectUnknown
        var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                self,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pointer,
                &resultSize,
                &result
            )
        }
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Resolve this process for tap exclusion", status: status)
        }
        guard result != kAudioObjectUnknown else {
            throw CallScribeCoreError.coreAudioFailure(
                operation: "Resolve this process for tap exclusion",
                status: kAudioHardwareBadObjectError
            )
        }
        return result
    }

    func inputChannelCount() throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr, size >= MemoryLayout<AudioBufferList>.size else {
            if status != noErr {
                throw CallScribeCoreError.coreAudioFailure(operation: "Read input stream configuration", status: status)
            }
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, storage)
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read input stream configuration", status: status)
        }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
