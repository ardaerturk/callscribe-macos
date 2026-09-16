@testable import CallScribeCore
import Foundation
import XCTest

final class CaptureCoordinatorTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testCapturedTracksShareOneMonotonicTimeline() throws {
        let clock = TestClock(1_000_000_000)
        let factory = FakeCaptureFactory()
        let coordinator = try makeCoordinator(clock: clock, factory: factory)
        let started = try coordinator.startCapture(microphoneUID: "chosen")
        XCTAssertEqual(started.manifest.microphoneUID, "chosen")

        factory.latest(.microphone)?.emit(CapturedPCMBlock(
            startNanoseconds: 1_000_000_000,
            sampleRate: 48_000,
            channels: [Array(repeating: 0.2, count: 480)]
        ))
        factory.latest(.system)?.emit(CapturedPCMBlock(
            startNanoseconds: 1_005_000_000,
            sampleRate: 48_000,
            channels: [Array(repeating: 0.4, count: 480)]
        ))

        let session = try coordinator.stopCapture()
        let microphone = try XCTUnwrap(session.manifest.chunks.first { $0.track == .microphone })
        let system = try XCTUnwrap(session.manifest.chunks.first { $0.track == .system })
        XCTAssertEqual(microphone.startFrame, 0)
        XCTAssertEqual(microphone.frameCount, 160)
        XCTAssertEqual(system.startFrame, 0, "leading timeline silence belongs in the system track chunk")
        XCTAssertEqual(system.frameCount, 240)
        XCTAssertTrue(session.manifest.events.contains {
            $0.kind == .gapInserted && $0.track == .system && $0.frameCount == 80
        })
    }

    func testPauseDropsOnlyMicrophonePackets() throws {
        let clock = TestClock(2_000_000_000)
        let factory = FakeCaptureFactory()
        let coordinator = try makeCoordinator(clock: clock, factory: factory)
        _ = try coordinator.startCapture()
        try coordinator.setMicrophonePaused(true)

        let packet = CapturedPCMBlock(
            startNanoseconds: 2_000_000_000,
            sampleRate: 16_000,
            channels: [[0.5, 0.5]]
        )
        factory.latest(.microphone)?.emit(packet)
        factory.latest(.system)?.emit(packet)

        let session = try coordinator.stopCapture()
        XCTAssertTrue(session.manifest.chunks.allSatisfy { $0.track != .microphone })
        XCTAssertEqual(session.manifest.chunks.first { $0.track == .system }?.frameCount, 2)
        XCTAssertTrue(session.manifest.events.contains { $0.kind == .microphonePaused })
    }

    func testSleepWakeAndRouteChangeRebuildSources() throws {
        let clock = TestClock(3_000_000_000)
        let factory = FakeCaptureFactory()
        let coordinator = try makeCoordinator(clock: clock, factory: factory)
        _ = try coordinator.startCapture()
        let firstMic = try XCTUnwrap(factory.latest(.microphone))
        let firstSystem = try XCTUnwrap(factory.latest(.system))

        coordinator.handleLifecycleEvent(.sleep)
        XCTAssertEqual(firstMic.stopCount, 1)
        XCTAssertEqual(firstSystem.stopCount, 1)

        coordinator.handleLifecycleEvent(.wake)
        XCTAssertEqual(factory.count(.microphone), 2)
        XCTAssertEqual(factory.count(.system), 2)

        coordinator.handleLifecycleEvent(.routeChanged(.system, "test route"))
        XCTAssertEqual(factory.count(.system), 3)

        let session = try coordinator.stopCapture()
        XCTAssertTrue(session.manifest.events.contains { $0.kind == .sleep })
        XCTAssertTrue(session.manifest.events.contains { $0.kind == .wake })
        XCTAssertTrue(session.manifest.events.contains { $0.kind == .routeChanged && $0.track == .system })
        XCTAssertGreaterThanOrEqual(
            session.manifest.events.filter { $0.kind == .captureRestarted }.count,
            3
        )
    }

    func testWatchdogRestartsStalledSourcesDeterministically() throws {
        let clock = TestClock(4_000_000_000)
        let factory = FakeCaptureFactory()
        let coordinator = try makeCoordinator(clock: clock, factory: factory, watchdogTimeout: 5)
        _ = try coordinator.startCapture()

        coordinator.checkWatchdog(at: 8_999_999_999)
        XCTAssertEqual(factory.count(.microphone), 1)
        XCTAssertEqual(factory.count(.system), 1)

        coordinator.checkWatchdog(at: 9_000_000_000)
        XCTAssertEqual(factory.count(.microphone), 2)
        XCTAssertEqual(factory.count(.system), 2)

        let session = try coordinator.stopCapture()
        XCTAssertEqual(session.manifest.events.filter { $0.kind == .captureStalled }.count, 2)
        XCTAssertEqual(session.manifest.events.filter { $0.kind == .captureRestarted }.count, 2)
    }

    func testMissingSavedMicrophoneFallsBackToDefaultAndSurfacesWarning() throws {
        let clock = TestClock(5_000_000_000)
        let factory = FakeCaptureFactory(unavailableMicrophoneUID: "gone")
        let coordinator = try makeCoordinator(clock: clock, factory: factory)

        let session = try coordinator.startCapture(microphoneUID: "gone")

        XCTAssertEqual(factory.microphoneRequests, ["gone", nil])
        XCTAssertEqual(session.manifest.microphoneUID, "default")
        guard case .recording(_, _, let warnings) = coordinator.status else {
            return XCTFail("expected recording status")
        }
        XCTAssertTrue(warnings.contains { $0.contains("current default input") })
        _ = try coordinator.stopCapture()
    }

    private func makeCoordinator(
        clock: TestClock,
        factory: FakeCaptureFactory,
        watchdogTimeout: TimeInterval = 8
    ) throws -> CaptureCoordinator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(root)
        let store = try SessionStore(rootURL: root)
        return CaptureCoordinator(
            sessionStore: store,
            configuration: CaptureConfiguration(
                chunkDurationSeconds: 15,
                watchdogIntervalSeconds: 0,
                watchdogTimeoutSeconds: watchdogTimeout,
                routeSettleSeconds: 0
            ),
            dependencies: CaptureCoordinatorDependencies(
                clock: clock,
                makeMicrophone: { try factory.makeMicrophone(uid: $0) },
                makeSystem: { factory.makeSystem() },
                observePowerEvents: false
            )
        )
    }
}

private final class TestClock: MonotonicNanosecondClock, @unchecked Sendable {
    var value: UInt64

    init(_ value: UInt64) { self.value = value }
    func now() -> UInt64 { value }
}

private final class FakeCaptureFactory: @unchecked Sendable {
    private(set) var sources: [AudioTrack: [FakeCaptureSource]] = [:]
    private(set) var microphoneRequests: [String?] = []
    let unavailableMicrophoneUID: String?

    init(unavailableMicrophoneUID: String? = nil) {
        self.unavailableMicrophoneUID = unavailableMicrophoneUID
    }

    func makeMicrophone(uid: String?) throws -> any AudioCaptureSource {
        microphoneRequests.append(uid)
        if let unavailableMicrophoneUID, uid == unavailableMicrophoneUID {
            throw CallScribeCoreError.inputDeviceUnavailable(uid ?? "default")
        }
        let selectedUID = uid ?? "default"
        return add(FakeCaptureSource(
            track: .microphone,
            inputDevice: AudioInputDevice(id: selectedUID, name: "Mic \(selectedUID)", isDefault: uid == nil)
        ))
    }

    func makeSystem() -> any AudioCaptureSource {
        add(FakeCaptureSource(track: .system, inputDevice: nil))
    }

    func latest(_ track: AudioTrack) -> FakeCaptureSource? { sources[track]?.last }
    func count(_ track: AudioTrack) -> Int { sources[track]?.count ?? 0 }

    private func add(_ source: FakeCaptureSource) -> FakeCaptureSource {
        sources[source.track, default: []].append(source)
        return source
    }
}

private final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let track: AudioTrack
    let inputDevice: AudioInputDevice?
    private var callbacks: CaptureSourceCallbacks?
    private(set) var stopCount = 0

    init(track: AudioTrack, inputDevice: AudioInputDevice?) {
        self.track = track
        self.inputDevice = inputDevice
    }

    func start(callbacks: CaptureSourceCallbacks) throws {
        self.callbacks = callbacks
    }

    func stop() {
        stopCount += 1
        callbacks = nil
    }

    func emit(_ block: CapturedPCMBlock) {
        callbacks?.activity()
        callbacks?.audio(block)
    }
}
