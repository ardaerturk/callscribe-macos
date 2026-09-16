import XCTest
import CallScribeCore
import CallScribeTranscription
@testable import CallScribeApp

final class AppControllerTests: XCTestCase {
    @MainActor
    func testCaptionToggleAndNewRecordingRejectStaleCaptionCallbacks() async throws {
        let suite = "CallScribeCaptionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = TestBackend()
        let controller = AppController(backend: backend, settings: AppSettings(defaults: defaults),
            requestMicrophoneAccess: { true }, clipboardWriter: { _ in })
        controller.bootstrap()
        await settle { controller.state == .idle }
        controller.toggleLiveCaptions()
        await settle { backend.captionsEnabled }
        controller.startRecording()
        await settle { controller.state == .recording }
        let oldCallback = try XCTUnwrap(backend.captionUpdate)
        oldCallback(.init(callText: "First meeting"))
        await settle { controller.liveCaption.callText == "First meeting" }
        controller.stopRecording()
        await settle { controller.state == .idle }
        controller.startRecording()
        await settle { controller.state == .recording }
        oldCallback(.init(callText: "Stale meeting"))
        backend.captionUpdate?(.init(callText: "Second meeting"))
        await settle { controller.liveCaption.callText == "Second meeting" }
        controller.toggleLiveCaptions()
        await settle { !backend.captionsEnabled }
        XCTAssertFalse(controller.settings.liveCaptionsEnabled)
        controller.stopRecording()
        await settle { controller.state == .idle }
    }

    @MainActor
    func testSubtitleFrameStaysAboveDockOnSecondaryScreen() {
        let screen = NSRect(x: -1920, y: 25, width: 1920, height: 1055)
        let frame = CaptionOverlay.frame(in: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertGreaterThan(frame.minY, screen.minY)
    }
    @MainActor
    func testManualLanguageIsPersistedAndCannotChangeDuringRecording() async throws {
        let suite = "CallScribeLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let backend = TestBackend()
        let controller = AppController(backend: backend, settings: settings,
            requestMicrophoneAccess: { true }, clipboardWriter: { _ in })
        controller.bootstrap()
        await settle { controller.state == .idle }
        controller.selectLanguage(.turkish)
        await settle { controller.state == .idle }
        XCTAssertEqual(AppSettings(defaults: defaults).language, .turkish)
        XCTAssertEqual(backend.lastReadinessLanguage, .turkish)
        controller.startRecording()
        controller.selectLanguage(.german)
        await settle { controller.state == .recording }
        controller.selectLanguage(.german)
        XCTAssertEqual(settings.language, .turkish)
        XCTAssertEqual(backend.recordedLanguage, .turkish)
        controller.stopRecording()
        await settle { controller.state == .idle }
        controller.selectLanguage(.german)
        await settle { controller.state == .idle }
        XCTAssertEqual(settings.language, .german)
    }
    @MainActor
    func testRapidStartStopInvocationsProduceOneSessionAndOneCopy() async throws {
        let backend = TestBackend()
        var copied: [String] = []
        let controller = AppController(backend: backend, requestMicrophoneAccess: { true }, clipboardWriter: { copied.append($0) })
        controller.bootstrap()
        await settle { controller.state == .idle }
        controller.startRecording()
        controller.startRecording()
        await settle { controller.state == .recording }
        XCTAssertEqual(backend.starts, 1)
        controller.stopRecording()
        controller.stopRecording()
        await settle { controller.state == .idle }
        XCTAssertEqual(backend.stops, 1)
        XCTAssertEqual(copied, ["You: A test transcript."])
    }

    @MainActor
    func testRecordingCanStartBeforeModelsArePrepared() async throws {
        let backend = TestBackend()
        backend.readiness = .notPrepared
        let controller = AppController(backend: backend, requestMicrophoneAccess: { true }, clipboardWriter: { _ in })
        controller.bootstrap()
        await settle { controller.state == .idle }
        controller.startRecording()
        await settle { controller.state == .recording }
        XCTAssertEqual(backend.starts, 1)
        controller.stopRecording()
        await settle { controller.state == .idle }
    }

    @MainActor
    func testFailedTranscriptionLeavesSavedSessionRetryable() async throws {
        let backend = TestBackend()
        backend.failProcessing = true
        let controller = AppController(backend: backend, requestMicrophoneAccess: { true }, clipboardWriter: { _ in XCTFail("Must not copy failed output") })
        controller.bootstrap()
        await settle { controller.state == .idle }
        controller.startRecording()
        await settle { controller.state == .recording }
        controller.stopRecording()
        await settle { if case .error = controller.state { return true }; return false }
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertTrue(controller.state.canStartOrStop)
    }

    @MainActor
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("State transition did not complete")
    }
}

@MainActor
private final class TestBackend: CallScribeBackend {
    nonisolated let sessionsDirectoryURL = URL(fileURLWithPath: "/test-sessions")
    var readiness: ModelReadiness = .ready
    var starts = 0
    var stops = 0
    var failProcessing = false
    var lastReadinessLanguage: TranscriptionLanguage?
    var recordedLanguage: TranscriptionLanguage?
    var captionsEnabled = false
    var captionUpdate: (@Sendable (LiveCaptionUpdate) -> Void)?
    func configureLiveCaptions(enabled: Bool, update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async {
        captionsEnabled = enabled
        captionUpdate = update
    }
    func prepareCaptionModels(progress: @escaping @Sendable (Double?) -> Void) async throws {}
    func currentModelReadiness(language: TranscriptionLanguage) async -> ModelReadiness {
        lastReadinessLanguage = language
        return readiness
    }
    func latestTranscript() async throws -> TranscriptResult? { nil }
    func repairArchive() async throws -> Int { failProcessing && stops > 0 ? 1 : 0 }
    func recordingWarning() async -> String? { nil }
    func prepareModels(language: TranscriptionLanguage, progress: @escaping @Sendable (Double?) -> Void) async throws { readiness = .ready }
    func startRecording(microphoneID: String?, language: TranscriptionLanguage) async throws {
        starts += 1
        recordedLanguage = language
    }
    func setMicrophonePaused(_ paused: Bool) async throws {}
    func stopAndTranscribe(formatting: TranscriptFormatting, keepAudio: KeepRecordingPolicy,
                          progress: @escaping @Sendable (Double?) -> Void) async throws -> TranscriptResult {
        stops += 1
        if failProcessing { throw CallScribeBackendError.unavailable("test processing failure") }
        return TranscriptResult(text: "You: A test transcript.", textFileURL: sessionsDirectoryURL.appendingPathComponent("transcript.txt"), sessionDirectoryURL: sessionsDirectoryURL)
    }
    func recoverInterruptedSession(formatting: TranscriptFormatting, keepAudio: KeepRecordingPolicy,
                                   progress: @escaping @Sendable (Double?) -> Void) async throws -> TranscriptResult? { nil }
}
