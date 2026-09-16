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

enum CoreAudioDeviceCatalog {
    static func inputDevices() throws -> [AudioInputDevice] {
        let devices: [AudioObjectID] = try AudioObjectID.system.readArray(
            selector: kAudioHardwarePropertyDevices
        )
        let defaultDevice: AudioObjectID = (try? AudioObjectID.system.readValue(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: kAudioObjectUnknown
        )) ?? kAudioObjectUnknown

        return try devices.compactMap { deviceID in
            guard try deviceID.inputChannelCount() > 0 else { return nil }
            let uid = try deviceID.readString(selector: kAudioDevicePropertyDeviceUID)
            let name = try deviceID.readString(selector: kAudioObjectPropertyName)
            return AudioInputDevice(id: uid, name: name, isDefault: deviceID == defaultDevice)
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func resolveInputDevice(uid: String?) throws -> (AudioObjectID, AudioInputDevice) {
        var id: AudioObjectID
        if let uid, !uid.isEmpty {
            id = try AudioObjectID.system.translateDeviceUID(uid)
            guard id != kAudioObjectUnknown, try id.inputChannelCount() > 0 else {
                throw CallScribeCoreError.inputDeviceUnavailable(uid)
            }
        } else {
            id = try AudioObjectID.system.readValue(
                selector: kAudioHardwarePropertyDefaultInputDevice,
                defaultValue: kAudioObjectUnknown
            )
            guard id != kAudioObjectUnknown, try id.inputChannelCount() > 0 else {
                throw CallScribeCoreError.inputDeviceUnavailable("default input")
            }
            // Opening a Bluetooth microphone can change headset playback quality.
            // Prefer a wired/built-in input unless the user explicitly selected it.
            let transport: UInt32 = (try? id.readValue(selector: kAudioDevicePropertyTransportType, defaultValue: 0)) ?? 0
            if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
                let all: [AudioObjectID] = try AudioObjectID.system.readArray(selector: kAudioHardwarePropertyDevices)
                if let alternative = all.first(where: { device in
                    let type: UInt32 = (try? device.readValue(selector: kAudioDevicePropertyTransportType, defaultValue: 0)) ?? 0
                    return type != kAudioDeviceTransportTypeBluetooth && type != kAudioDeviceTransportTypeBluetoothLE
                        && ((try? device.inputChannelCount()) ?? 0) > 0
                }) { id = alternative }
            }
        }

        let resolvedUID = try id.readString(selector: kAudioDevicePropertyDeviceUID)
        let name = try id.readString(selector: kAudioObjectPropertyName)
        let defaultID: AudioObjectID = (try? AudioObjectID.system.readValue(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: kAudioObjectUnknown
        )) ?? kAudioObjectUnknown
        return (id, AudioInputDevice(id: resolvedUID, name: name, isDefault: id == defaultID))
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
