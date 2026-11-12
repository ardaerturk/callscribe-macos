import AudioToolbox
import CoreAudio
import Foundation

struct MeetingOutputCandidate: Equatable {
    let deviceID: AudioObjectID
    let uid: String
    let name: String
    let browser: Bool
    let inputActive: Bool
    var sampleRate: Double = 0
    var channelCount: UInt32 = 0
    var bluetooth: Bool = false

    func captureFormatChanged(from other: Self) -> Bool {
        uid != other.uid || sampleRate != other.sampleRate || channelCount != other.channelCount
    }
}

/// WebRTC can use a headset while media/default output stays on the speakers.
/// Follow the browser's actual output device rather than the global mixdown.
enum SystemAudioRouting {
    static func select(_ candidates: [MeetingOutputCandidate], defaultDevice: MeetingOutputCandidate) -> MeetingOutputCandidate {
        candidates.filter(\.browser).sorted {
            if $0.inputActive != $1.inputActive { return $0.inputActive }
            if $0.bluetooth != $1.bluetooth { return $0.bluetooth }
            if ($0.deviceID == defaultDevice.deviceID) != ($1.deviceID == defaultDevice.deviceID) {
                // A browser-selected device can differ from ordinary media.
                // One audio helper may own both its media and WebRTC streams.
                return $0.deviceID != defaultDevice.deviceID
            }
            return $0.uid < $1.uid
        }.first ?? defaultDevice
    }

    static func isMeetingApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return ["com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "org.mozilla.firefox",
                "com.apple.safari", "us.zoom.", "com.microsoft.teams"].contains { id.hasPrefix($0) }
    }

    static func current() throws -> MeetingOutputCandidate {
        let defaultID: AudioObjectID = try AudioObjectID.system.readValue(
            selector: kAudioHardwarePropertyDefaultOutputDevice, defaultValue: kAudioObjectUnknown)
        func device(_ id: AudioObjectID, browser: Bool, input: Bool) -> MeetingOutputCandidate? {
            guard id != kAudioObjectUnknown,
                  let streams: [AudioObjectID] = try? id.readArray(selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                  !streams.isEmpty,
                  let uid = try? id.readString(selector: kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("app.callscribe.capture."),
                  let name = try? id.readString(selector: kAudioObjectPropertyName) else { return nil }
            let format = (try? streams[0].readValue(selector: kAudioStreamPropertyVirtualFormat,
                defaultValue: AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
            let transport: UInt32 = (try? id.readValue(selector: kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
            return .init(deviceID: id, uid: uid, name: name, browser: browser, inputActive: input,
                sampleRate: format.mSampleRate, channelCount: format.mChannelsPerFrame,
                bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
        func outputDevices(_ id: AudioObjectID, browser: Bool, input: Bool) -> [MeetingOutputCandidate] {
            // Chrome can expose an internal duplex aggregate rather than the
            // headset directly. Tap its physical output, never its mic stream.
            let children: [AudioObjectID] = (try? id.readArray(selector: kAudioAggregateDevicePropertyActiveSubDeviceList)) ?? []
            if !children.isEmpty {
                return children.compactMap { device($0, browser: browser, input: input) }
            }
            return device(id, browser: browser, input: input).map { [$0] } ?? []
        }
        guard let fallback = device(defaultID, browser: false, input: false) else {
            throw CallScribeCoreError.invalidAudioFormat("No available output device for call audio")
        }
        let processes: [AudioObjectID] = (try? AudioObjectID.system.readArray(selector: kAudioHardwarePropertyProcessObjectList)) ?? []
        var candidates: [MeetingOutputCandidate] = []
        for process in processes {
            guard let bundle = try? process.readString(selector: kAudioProcessPropertyBundleID), isMeetingApp(bundle),
                  let running: UInt32 = try? process.readValue(selector: kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)),
                  running != 0 else { continue }
            let input: UInt32 = (try? process.readValue(selector: kAudioProcessPropertyIsRunningInput, defaultValue: UInt32(0))) ?? 0
            let outputs: [AudioObjectID] = (try? process.readArray(selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? []
            candidates += outputs.flatMap { outputDevices($0, browser: true, input: input != 0) }
        }
        return select(candidates, defaultDevice: fallback)
    }
}

public struct CaptureAudioStatus: Equatable, Sendable {
    public let microphoneActive: Bool
    public let callAudioActive: Bool
    public let callAudioEverReceived: Bool
    public let outputName: String
    public let microphonePaused: Bool
}

/// Signal detection is separate from IO liveness: silence callbacks are not proof
/// that the other participants are being captured. Keep only levels/timestamps.
struct CaptureSignalTracker {
    private(set) var lastAudible: [AudioTrack: UInt64] = [:]
    mutating func observe(_ samples: [Float], track: AudioTrack, at now: UInt64) {
        guard !samples.isEmpty else { return }
        var square: Double = 0
        var peak: Float = 0
        for value in samples where value.isFinite {
            square += Double(value) * Double(value)
            peak = max(peak, abs(value))
        }
        if peak >= 0.002 && square / Double(samples.count) >= 0.000_000_09 {
            lastAudible[track] = now
        }
    }
    func active(_ track: AudioTrack, at now: UInt64) -> Bool {
        guard let last = lastAudible[track], now >= last else { return false }
        return now - last < 3_000_000_000
    }
}
