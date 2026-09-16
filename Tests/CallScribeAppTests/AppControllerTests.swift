import XCTest
@testable import CallScribeApp

final class AppControllerTests: XCTestCase {
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
    func currentModelReadiness() async -> ModelReadiness { readiness }
    func latestTranscript() async throws -> TranscriptResult? { nil }
    func repairArchive() async throws -> Int { failProcessing && stops > 0 ? 1 : 0 }
    func recordingWarning() async -> String? { nil }
    func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws { readiness = .ready }
    func startRecording(microphoneID: String?) async throws { starts += 1 }
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
