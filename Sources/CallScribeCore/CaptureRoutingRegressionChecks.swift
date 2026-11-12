import CoreAudio
import Foundation

/// Deterministic verification; opens no audio input or output.
public enum CaptureRoutingRegressionChecks {
    public static func run() throws {
        func check(_ valid: Bool, _ message: String) throws {
            if !valid { throw CallScribeCoreError.invalidAudioFormat("Regression: " + message) }
        }
        let speakers = MeetingOutputCandidate(deviceID: 1, uid: "speakers", name: "Speakers", browser: false, inputActive: false)
        let airpods = MeetingOutputCandidate(deviceID: 2, uid: "airpods", name: "AirPods", browser: true, inputActive: true)
        let media = MeetingOutputCandidate(deviceID: 1, uid: "speakers", name: "Speakers", browser: true, inputActive: false)
        try check(SystemAudioRouting.select([media, airpods], defaultDevice: speakers) == airpods,
                  "WebRTC headset wins over browser media on default speakers")
        var sharedHelperMedia = media
        sharedHelperMedia = .init(deviceID: 1, uid: "speakers", name: "Speakers", browser: true, inputActive: true)
        var sharedHelperHeadset = airpods
        sharedHelperHeadset.bluetooth = true
        try check(SystemAudioRouting.select([sharedHelperMedia, sharedHelperHeadset], defaultDevice: speakers) == sharedHelperHeadset,
                  "one Chrome helper owning both media and WebRTC keeps the selected headset route")
        try check(SystemAudioRouting.select([], defaultDevice: speakers) == speakers, "disconnected headset falls back to output")
        var stereo = airpods
        stereo.sampleRate = 48_000; stereo.channelCount = 2
        var handsFree = stereo
        handsFree.sampleRate = 24_000; handsFree.channelCount = 1
        try check(handsFree.captureFormatChanged(from: stereo) && !stereo.captureFormatChanged(from: stereo),
                  "AirPods profile changes invalidate capture with the same device UID")
        try check(SystemAudioRouting.isMeetingApp("com.google.Chrome.helper") && !SystemAudioRouting.isMeetingApp("app.aifirm.callscribe"),
                  "Chrome audio helpers participate in route detection")
        var signals = CaptureSignalTracker()
        signals.observe([0, 0, 0], track: .system, at: 1)
        try check(signals.lastAudible[.system] == nil, "silence callbacks do not confirm call audio")
        signals.observe([0.1, -0.1], track: .system, at: 2)
        try check(signals.active(.system, at: 3) && !signals.active(.system, at: 3_000_000_003),
                  "audible call signal is detected and becomes quiet")
        let tap = CoreAudioSystemSource.makeTapDescription(excludingProcessID: 42, outputUID: "airpods")
        try check(tap.deviceUID == "airpods" && tap.processes == [42] && tap.muteBehavior == .unmuted,
                  "device-bound tap preserves normal playback and excludes the app")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CallScribe-route-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try SessionStore(rootURL: temporary)
        let clock = VerificationClock()
        let microphone = VerificationSource(track: .microphone)
        let call = VerificationSource(track: .system)
        let coordinator = CaptureCoordinator(sessionStore: store,
            configuration: .init(watchdogIntervalSeconds: 0, watchdogTimeoutSeconds: 60, routeSettleSeconds: 0),
            dependencies: .init(clock: clock, makeMicrophone: { _ in microphone }, makeSystem: { call }, observePowerEvents: false))
        _ = try coordinator.startCapture()
        defer { _ = try? coordinator.stopCapture() }
        microphone.emit([0.1, -0.1], at: 0)
        call.emit([0, 0], at: 0)
        _ = try coordinator.currentSession() // Drain queued fixture callbacks.
        clock.advance(to: 21_000_000_000)
        coordinator.checkWatchdog()
        if case .recording(_, _, let warnings) = coordinator.status {
            try check(warnings.contains(where: { $0.contains("Call audio has been quiet") }),
                      "silence callbacks produce a visible warning despite healthy IO")
        } else { try check(false, "coordinator remains recording") }
        coordinator.refreshCallAudio()
        try check(call.starts == 2 && microphone.starts == 1 && microphone.stops == 0,
                  "call-audio refresh never restarts the microphone")
        try coordinator.setMicrophonePaused(true)
        call.emit([0.1, -0.1], at: clock.now())
        _ = try coordinator.currentSession()
        try check(coordinator.audioStatus?.callAudioActive == true && coordinator.audioStatus?.microphonePaused == true,
                  "new call signal is detected while microphone pause is preserved")
        if case .recording(_, _, let warnings) = coordinator.status {
            try check(!warnings.contains(where: { $0.contains("Call audio has been quiet") }), "signal clears transient silence warning")
        }
        clock.advance(to: 42_000_000_000)
        if case .recording(_, _, let warnings) = coordinator.status {
            try check(warnings.contains(where: { $0.contains("Call audio has been quiet") }),
                      "an early notification cannot hide a later silent call track")
        }
        _ = try coordinator.stopCapture()
        try check(coordinator.audioStatus == nil, "Stop clears live signal status")
    }
}

private final class VerificationClock: MonotonicNanosecondClock, @unchecked Sendable {
    private var value: UInt64 = 0
    func now() -> UInt64 { value }
    func advance(to value: UInt64) { self.value = value }
}

private final class VerificationSource: AudioCaptureSource, @unchecked Sendable {
    let track: AudioTrack
    let inputDevice: AudioInputDevice? = nil
    var outputDeviceName: String? { track == .system ? "Fixture headset" : nil }
    private var callbacks: CaptureSourceCallbacks?
    private(set) var starts = 0
    private(set) var stops = 0
    init(track: AudioTrack) { self.track = track }
    func start(callbacks: CaptureSourceCallbacks) throws { self.callbacks = callbacks; starts += 1 }
    func stop() { if callbacks != nil { stops += 1 }; callbacks = nil }
    func emit(_ samples: [Float], at time: UInt64) {
        callbacks?.activity()
        callbacks?.audio(.init(startNanoseconds: time, sampleRate: 16_000, channels: [samples]))
    }
}
