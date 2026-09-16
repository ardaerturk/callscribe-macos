import Foundation
import CallScribeCore
import CallScribeTranscription

enum RecordingState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case microphonePaused
    case recovering
    case processing(progress: Double?)
    case error(message: String)

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .starting:
            return "Starting recording"
        case .recording:
            return "Recording"
        case .microphonePaused:
            return "Recording - microphone paused"
        case .recovering:
            return "Checking saved sessions and models"
        case .processing:
            return "Creating transcript"
        case .error:
            return "Needs attention"
        }
    }

    var isCapturing: Bool {
        switch self {
        case .recording, .microphonePaused:
            return true
        case .idle, .starting, .recovering, .processing, .error:
            return false
        }
    }

    var canStartOrStop: Bool {
        switch self {
        case .idle, .recording, .microphonePaused, .error:
            return true
        case .starting, .recovering, .processing:
            return false
        }
    }
}

enum ModelReadiness: Equatable, Sendable {
    case notPrepared
    case downloading(progress: Double?)
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .notPrepared:
            return "Offline models not prepared"
        case .downloading:
            return "Preparing offline models"
        case .ready:
            return "Offline models ready"
        case .failed:
            return "Model preparation failed"
        }
    }
}

struct TranscriptResult: Sendable {
    let text: String
    let textFileURL: URL
    let sessionDirectoryURL: URL
}

enum CallScribeBackendError: LocalizedError {
    case unavailable(String)
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .noTranscript:
            return "No transcript was produced. The audio remains in the session archive so processing can be retried."
        }
    }
}

/// Narrow boundary between the menu-bar lifecycle and the capture/transcription
/// implementation. Keeping this adapter small also makes capture recovery testable
/// without launching AppKit.
protocol CallScribeBackend: AnyObject {
    var sessionsDirectoryURL: URL { get }

    func currentModelReadiness(language: TranscriptionLanguage) async -> ModelReadiness
    func latestTranscript() async throws -> TranscriptResult?
    func repairArchive() async throws -> Int
    func recordingWarning() async -> String?
    func configureLiveCaptions(enabled: Bool, update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async
    func prepareCaptionModels(progress: @escaping @Sendable (Double?) -> Void) async throws
    func prepareModels(language: TranscriptionLanguage, progress: @escaping @Sendable (Double?) -> Void) async throws
    func startRecording(microphoneID: String?, language: TranscriptionLanguage) async throws
    func setMicrophonePaused(_ paused: Bool) async throws
    func stopAndTranscribe(
        formatting: TranscriptFormatting,
        keepAudio: KeepRecordingPolicy,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> TranscriptResult
    func recoverInterruptedSession(
        formatting: TranscriptFormatting,
        keepAudio: KeepRecordingPolicy,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> TranscriptResult?
}
