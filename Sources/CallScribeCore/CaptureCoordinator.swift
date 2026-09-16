import AppKit
import Foundation

public struct CaptureConfiguration: Equatable, Sendable {
    public var chunkDurationSeconds: TimeInterval
    public var watchdogIntervalSeconds: TimeInterval
    public var watchdogTimeoutSeconds: TimeInterval
    public var routeSettleSeconds: TimeInterval

    public init(
        chunkDurationSeconds: TimeInterval = 15,
        watchdogIntervalSeconds: TimeInterval = 2,
        watchdogTimeoutSeconds: TimeInterval = 8,
        routeSettleSeconds: TimeInterval = 0.75
    ) {
        self.chunkDurationSeconds = max(0.1, chunkDurationSeconds)
        self.watchdogIntervalSeconds = max(0, watchdogIntervalSeconds)
        self.watchdogTimeoutSeconds = max(1, watchdogTimeoutSeconds)
        self.routeSettleSeconds = max(0, routeSettleSeconds)
    }
}

enum CaptureLifecycleEvent: Sendable {
    case sleep
    case wake
    case routeChanged(AudioTrack, String)
    case sourceFailed(AudioTrack, String)
}

struct CaptureCoordinatorDependencies: @unchecked Sendable {
    let clock: any MonotonicNanosecondClock
    let makeMicrophone: @Sendable (String?) throws -> any AudioCaptureSource
    let makeSystem: @Sendable () throws -> any AudioCaptureSource
    let observePowerEvents: Bool

    static func live(clock: any MonotonicNanosecondClock = AudioHostClock()) -> Self {
        Self(
            clock: clock,
            makeMicrophone: { try AVAudioEngineMicrophoneSource(deviceUID: $0, clock: clock) },
            makeSystem: {
                guard #available(macOS 14.2, *) else {
                    throw CallScribeCoreError.invalidAudioFormat("system audio capture requires macOS 14.2 or later")
                }
                return CoreAudioSystemSource(clock: clock)
            },
            observePowerEvents: true
        )
    }
}

/// Coordinates microphone and global process-tap capture into a durable,
/// frame-aligned session. All lifecycle transitions and audio processing are
/// serialized, while each real-time callback only copies its source buffer.
public final class CaptureCoordinator: @unchecked Sendable {
    public typealias StatusHandler = @Sendable (CaptureStatus) -> Void

    private let sessionStore: SessionStore
    private let configuration: CaptureConfiguration
    private let dependencies: CaptureCoordinatorDependencies
    private let queue = DispatchQueue(label: "app.callscribe.capture.coordinator", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    private var statusValue: CaptureStatus = .idle
    private var statusHandler: StatusHandler?
    private var recorder: SessionRecorder?
    private var timeline: MonotonicAudioTimeline?
    private var sessionGeneration: UUID?
    private var sources: [AudioTrack: any AudioCaptureSource] = [:]
    private var sourceTokens: [AudioTrack: UUID] = [:]
    private var desiredTracks = Set<AudioTrack>()
    // User preference, not the last resolved device. nil must remain Automatic
    // across restarts, and a missing explicit device must remain retryable.
    private var requestedMicrophoneUID: String?
    private var microphonePaused = false
    private var warnings: [String] = []
    private var health = CaptureHealthTracker()
    private var watchdog: DispatchSourceTimer?
    private var powerObservers: [NSObjectProtocol] = []
    private var routeRestartItems: [AudioTrack: DispatchWorkItem] = [:]

    public convenience init(
        sessionStore: SessionStore,
        configuration: CaptureConfiguration = CaptureConfiguration()
    ) {
        self.init(
            sessionStore: sessionStore,
            configuration: configuration,
            dependencies: .live()
        )
    }

    public convenience init(configuration: CaptureConfiguration = CaptureConfiguration()) throws {
        try self.init(sessionStore: SessionStore(), configuration: configuration)
    }

    init(
        sessionStore: SessionStore,
        configuration: CaptureConfiguration,
        dependencies: CaptureCoordinatorDependencies
    ) {
        self.sessionStore = sessionStore
        self.configuration = configuration
        self.dependencies = dependencies
        queue.setSpecific(key: queueKey, value: ())
    }

    public var status: CaptureStatus {
        onQueue {
            if case .recording(let id, let paused, let warnings) = statusValue,
               let error = recorder?.lastStorageError {
                return .recording(sessionID: id, microphonePaused: paused,
                    warnings: warnings + ["Audio storage needs attention: \(error)"])
            }
            return statusValue
        }
    }

    public static func availableInputDevices() throws -> [AudioInputDevice] {
        try CoreAudioDeviceCatalog.inputDevices()
    }

    /// Status callbacks are delivered asynchronously on the main queue. Passing
    /// nil removes the current callback.
    public func setStatusHandler(_ handler: StatusHandler?) {
        onQueue { statusHandler = handler }
    }

    @discardableResult
    public func startCapture(microphoneUID: String? = nil) throws -> RecordingSession {
        try onQueue {
            guard recorder == nil else { throw CallScribeCoreError.captureAlreadyRunning }
            setStatus(.starting)

            self.requestedMicrophoneUID = microphoneUID.flatMap { $0.isEmpty ? nil : $0 }
            microphonePaused = false
            warnings = []
            desiredTracks = Set(AudioTrack.allCases)
            health = CaptureHealthTracker()
            let generation = UUID()
            sessionGeneration = generation
            timeline = MonotonicAudioTimeline(originNanoseconds: dependencies.clock.now())

            let activeRecorder: SessionRecorder
            do {
                activeRecorder = try sessionStore.beginSession(
                    microphoneUID: microphoneUID,
                    chunkDurationSeconds: configuration.chunkDurationSeconds
                )
            } catch {
                clearActiveState()
                setStatus(.failed(message: error.localizedDescription))
                throw error
            }
            recorder = activeRecorder

            var failures: [String] = []
            for track in [AudioTrack.microphone, .system] {
                do {
                    try startSource(track, generation: generation, restarting: false)
                } catch {
                    let message = "\(track.rawValue) capture unavailable: \(error.localizedDescription)"
                    failures.append(message)
                    appendWarning(message)
                    activeRecorder.record(CaptureEvent(kind: .warning, track: track, message: message))
                    health.started(track, at: dependencies.clock.now())
                }
            }

            guard !sources.isEmpty else {
                let failure = CallScribeCoreError.noCaptureSourceAvailable(failures)
                _ = try? activeRecorder.finish(state: .failed, failureReason: failure.localizedDescription)
                clearActiveState()
                setStatus(.failed(message: failure.localizedDescription))
                throw failure
            }

            installPowerObserversIfNeeded()
            startWatchdogIfNeeded()
            setRecordingStatus()
            return try activeRecorder.snapshot()
        }
    }

    /// Alias used by simple integrations.
    @discardableResult
    public func start(microphoneUID: String? = nil) throws -> RecordingSession {
        try startCapture(microphoneUID: microphoneUID)
    }

    public func setMicrophonePaused(_ paused: Bool) throws {
        try onQueue {
            guard let recorder, sessionGeneration != nil else {
                throw CallScribeCoreError.captureNotRunning
            }
            guard microphonePaused != paused else { return }
            microphonePaused = paused
            recorder.record(CaptureEvent(
                kind: paused ? .microphonePaused : .microphoneResumed,
                track: .microphone,
                frame: currentFrame(),
                message: paused ? "Microphone capture paused" : "Microphone capture resumed"
            ))
            setRecordingStatus()
        }
    }

    @discardableResult
    public func stopCapture() throws -> RecordingSession {
        try onQueue {
            guard let recorder, let generation = sessionGeneration else {
                throw CallScribeCoreError.captureNotRunning
            }
            setStatus(.stopping(sessionID: recorder.id))
            sessionGeneration = nil
            cancelInfrastructure()
            for source in sources.values { source.stop() }
            sources.removeAll()
            sourceTokens.removeAll()
            desiredTracks.removeAll()
            timeline = nil

            do {
                let session = try recorder.finish()
                clearActiveState()
                setStatus(.idle)
                _ = generation // Makes the invalidation ordering explicit.
                return session
            } catch {
                clearActiveState()
                setStatus(.failed(message: error.localizedDescription))
                throw error
            }
        }
    }

    @discardableResult
    public func stop() throws -> RecordingSession {
        try stopCapture()
    }

    public func currentSession() throws -> RecordingSession? {
        try onQueue { try recorder?.snapshot() }
    }

    private func startSource(
        _ track: AudioTrack,
        generation: UUID,
        restarting: Bool
    ) throws {
        let source: any AudioCaptureSource
        switch track {
        case .microphone:
            do {
                source = try dependencies.makeMicrophone(requestedMicrophoneUID)
            } catch {
                guard requestedMicrophoneUID != nil else { throw error }
                source = try dependencies.makeMicrophone(nil)
                let message = "Selected microphone is unavailable; using automatic input: \(source.inputDevice?.name ?? "available microphone")"
                appendWarning(message)
                recorder?.record(CaptureEvent(
                    kind: .warning,
                    track: .microphone,
                    frame: currentFrame(),
                    message: message
                ))
            }
            if let input = source.inputDevice {
                recorder?.updateMicrophone(uid: input.uid, name: input.name)
            }
        case .system:
            source = try dependencies.makeSystem()
        }

        let token = UUID()
        sourceTokens[track] = token
        let callbacks = CaptureSourceCallbacks(
            audio: { [weak self] block in
                self?.queue.async { [weak self] in
                    self?.receive(block, from: track, generation: generation, sourceToken: token)
                }
            },
            activity: { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self,
                          self.sessionGeneration == generation,
                          self.sourceTokens[track] == token else { return }
                    self.health.observed(track, at: self.dependencies.clock.now())
                }
            },
            invalidated: { [weak self] invalidation in
                self?.queue.async { [weak self] in
                    guard let self,
                          self.sessionGeneration == generation,
                          self.sourceTokens[track] == token else { return }
                    switch invalidation {
                    case .routeChanged(let message):
                        self.handleLifecycleEvent(.routeChanged(track, message))
                    case .failed(let message):
                        self.handleLifecycleEvent(.sourceFailed(track, message))
                    }
                }
            }
        )

        do {
            try source.start(callbacks: callbacks)
            sources[track] = source
            health.started(track, at: dependencies.clock.now())
            if restarting {
                recorder?.record(CaptureEvent(
                    kind: .captureRestarted,
                    track: track,
                    frame: currentFrame(),
                    message: "\(track.rawValue) capture restarted"
                ))
            }
        } catch {
            sourceTokens.removeValue(forKey: track)
            source.stop()
            throw error
        }
    }

    private func receive(
        _ block: CapturedPCMBlock,
        from track: AudioTrack,
        generation: UUID,
        sourceToken: UUID
    ) {
        guard sessionGeneration == generation,
              sourceTokens[track] == sourceToken,
              let timeline,
              let recorder else { return }
        health.observed(track, at: dependencies.clock.now())
        if track == .microphone && microphonePaused { return }
        do {
            let aligned = try timeline.convert(block)
            recorder.append(aligned.samples, to: track, startFrame: aligned.startFrame)
        } catch {
            let message = "\(track.rawValue) conversion failed: \(error.localizedDescription)"
            appendWarning(message)
            recorder.record(CaptureEvent(kind: .warning, track: track, message: message))
            setRecordingStatus()
        }
    }

    func handleLifecycleEvent(_ event: CaptureLifecycleEvent) {
        onQueue {
            guard let recorder, let generation = sessionGeneration else { return }
            switch event {
            case .sleep:
                guard !health.sleeping else { return }
                recorder.record(CaptureEvent(kind: .sleep, frame: currentFrame(), message: "Mac is going to sleep"))
                health.setSleeping(true)
                for item in routeRestartItems.values { item.cancel() }
                routeRestartItems.removeAll()
                for source in sources.values { source.stop() }
                sources.removeAll()
                sourceTokens.removeAll()

            case .wake:
                guard health.sleeping else { return }
                recorder.record(CaptureEvent(kind: .wake, frame: currentFrame(), message: "Mac woke from sleep"))
                health.setSleeping(false)
                for track in desiredTracks.sorted(by: { $0.rawValue < $1.rawValue }) {
                    restartSource(track, generation: generation, reason: "wake")
                }

            case .routeChanged(let track, let message):
                recorder.record(CaptureEvent(
                    kind: .routeChanged,
                    track: track,
                    frame: currentFrame(),
                    message: message
                ))
                scheduleRouteRestart(track, generation: generation, reason: message)

            case .sourceFailed(let track, let message):
                recorder.record(CaptureEvent(
                    kind: .captureStalled,
                    track: track,
                    frame: currentFrame(),
                    message: message
                ))
                restartSource(track, generation: generation, reason: message)
            }
        }
    }

    func checkWatchdog(at now: UInt64? = nil) {
        onQueue {
            guard let recorder, let generation = sessionGeneration, !health.sleeping else { return }
            let timestamp = now ?? dependencies.clock.now()
            let timeout = UInt64(configuration.watchdogTimeoutSeconds * 1_000_000_000)
            for track in health.stalledTracks(at: timestamp, timeoutNanoseconds: timeout) {
                recorder.record(CaptureEvent(
                    kind: .captureStalled,
                    track: track,
                    frame: currentFrame(),
                    message: "No \(track.rawValue) capture callback for \(configuration.watchdogTimeoutSeconds) seconds"
                ))
                health.started(track, at: timestamp)
                restartSource(track, generation: generation, reason: "watchdog timeout")
            }
        }
    }

    private func scheduleRouteRestart(_ track: AudioTrack, generation: UUID, reason: String) {
        routeRestartItems[track]?.cancel()
        if configuration.routeSettleSeconds == 0 {
            restartSource(track, generation: generation, reason: reason)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  !self.health.sleeping else { return }
            self.routeRestartItems.removeValue(forKey: track)
            self.restartSource(track, generation: generation, reason: reason)
        }
        routeRestartItems[track] = item
        queue.asyncAfter(deadline: .now() + configuration.routeSettleSeconds, execute: item)
    }

    private func restartSource(_ track: AudioTrack, generation: UUID, reason: String) {
        guard sessionGeneration == generation, desiredTracks.contains(track), !health.sleeping else { return }
        sourceTokens.removeValue(forKey: track)
        if let source = sources.removeValue(forKey: track) { source.stop() }
        health.remove(track)
        do {
            try startSource(track, generation: generation, restarting: true)
        } catch {
            let message = "Could not restart \(track.rawValue) capture after \(reason): \(error.localizedDescription)"
            appendWarning(message)
            health.started(track, at: dependencies.clock.now())
            recorder?.record(CaptureEvent(
                kind: .captureRestartFailed,
                track: track,
                frame: currentFrame(),
                message: message
            ))
            setRecordingStatus()
        }
    }

    private func installPowerObserversIfNeeded() {
        guard dependencies.observePowerEvents, powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.handleLifecycleEvent(.sleep) }
        })
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.handleLifecycleEvent(.wake) }
        })
    }

    private func startWatchdogIfNeeded() {
        guard configuration.watchdogIntervalSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + configuration.watchdogIntervalSeconds,
            repeating: configuration.watchdogIntervalSeconds,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        timer.resume()
        watchdog = timer
    }

    private func cancelInfrastructure() {
        watchdog?.cancel()
        watchdog = nil
        for item in routeRestartItems.values { item.cancel() }
        routeRestartItems.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for observer in powerObservers { center.removeObserver(observer) }
        powerObservers.removeAll()
    }

    private func appendWarning(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }

    private func currentFrame() -> Int64? {
        guard let timeline else { return nil }
        return timeline.frame(at: dependencies.clock.now())
    }

    private func setRecordingStatus() {
        guard let recorder else { return }
        setStatus(.recording(
            sessionID: recorder.id,
            microphonePaused: microphonePaused,
            warnings: warnings
        ))
    }

    private func setStatus(_ status: CaptureStatus) {
        statusValue = status
        guard let statusHandler else { return }
        DispatchQueue.main.async { statusHandler(status) }
    }

    private func clearActiveState() {
        recorder = nil
        timeline = nil
        sessionGeneration = nil
        sources.removeAll()
        sourceTokens.removeAll()
        desiredTracks.removeAll()
        requestedMicrophoneUID = nil
        microphonePaused = false
        warnings = []
        health = CaptureHealthTracker()
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    deinit {
        onQueue {
            sessionGeneration = nil
            cancelInfrastructure()
            for source in sources.values { source.stop() }
            sources.removeAll()
            _ = try? recorder?.finish(state: .interrupted, failureReason: "Capture coordinator was released")
            clearActiveState()
        }
    }
}
