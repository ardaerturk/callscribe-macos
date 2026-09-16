import CallScribeCore
import CallScribeTranscription
import Foundation

actor CoreBackendAdapter: CallScribeBackend {
    nonisolated let sessionsDirectoryURL: URL
    private var processor: MeetingNotesProcessor?
    private var processorLanguage: TranscriptionLanguage?
    private let diarizer = FluidAudioSpeakerDiarizer()
    private var coordinator: CaptureCoordinator?
    private var store: SessionStore?

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionsDirectoryURL = support.appendingPathComponent("CallScribe/Sessions", isDirectory: true)
    }

    private func sessionStore() throws -> SessionStore {
        if let store { return store }
        let created = try SessionStore(rootURL: sessionsDirectoryURL)
        store = created
        return created
    }

    private func processor(for language: TranscriptionLanguage) -> MeetingNotesProcessor {
        if processorLanguage == language, let processor { return processor }
        // Release the previous speech model instead of retaining three loaded
        // model sets. Turkish and German share the same on-disk Whisper files.
        processor = nil
        let created = MeetingNotesProcessor(language: language, speakerDiarizer: diarizer)
        processor = created
        processorLanguage = language
        return created
    }

    func currentModelReadiness(language: TranscriptionLanguage) async -> ModelReadiness {
        let processor = processor(for: language)
        if await processor.modelsArePrepared { return .ready }
        do {
            try await processor.prepareModels(allowDownloads: false)
            return .ready
        } catch {
            return .notPrepared
        }
    }

    func prepareModels(language: TranscriptionLanguage, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let processor = processor(for: language)
        try await processor.prepareModels { progress($0) }
    }

    func latestTranscript() throws -> TranscriptResult? {
        for session in try sessionStore().sessions() {
            let url = session.directoryURL.appendingPathComponent("transcript.txt")
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return TranscriptResult(text: text, textFileURL: url, sessionDirectoryURL: session.directoryURL)
            }
        }
        return nil
    }

    func repairArchive() throws -> Int {
        _ = try sessionStore().recoverInterruptedSessions()
        return try pendingSessions().count
    }

    func recordingWarning() -> String? {
        guard let coordinator else { return nil }
        if case .recording(_, _, let warnings) = coordinator.status {
            return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        }
        return nil
    }

    func startRecording(microphoneID: String?, language: TranscriptionLanguage) throws {
        if coordinator == nil { coordinator = CaptureCoordinator(sessionStore: try sessionStore()) }
        try coordinator?.startCapture(microphoneUID: microphoneID, language: language)
    }

    func setMicrophonePaused(_ paused: Bool) throws {
        guard let coordinator else { throw CallScribeCoreError.captureNotRunning }
        try coordinator.setMicrophonePaused(paused)
    }

    func stopAndTranscribe(
        formatting: TranscriptFormatting,
        keepAudio: KeepRecordingPolicy,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> TranscriptResult {
        guard let coordinator else { throw CallScribeCoreError.captureNotRunning }
        let session = try coordinator.stopCapture()
        return try await transcribe(session, formatting: formatting, progress: progress)
    }

    func recoverInterruptedSession(
        formatting: TranscriptFormatting,
        keepAudio: KeepRecordingPolicy,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> TranscriptResult? {
        _ = try sessionStore().recoverInterruptedSessions()
        let sessions = try pendingSessions().reversed()
        var latest: TranscriptResult?
        var lastFailure: Error?
        for (index, session) in sessions.enumerated() {
            do {
                latest = try await transcribe(session, formatting: formatting) { value in
                    progress((Double(index) + (value ?? 0)) / Double(sessions.count))
                }
            } catch {
                lastFailure = error
            }
        }
        if latest == nil, let lastFailure { throw lastFailure }
        return latest
    }

    private func pendingSessions() throws -> [RecordingSession] {
        try sessionStore().sessions().filter { session in
            guard session.manifest.state != .recording, !session.manifest.chunks.isEmpty else { return false }
            let stateURL = session.directoryURL.appendingPathComponent(TranscriptFileNames.processingState)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? decoder.decode(TranscriptProcessingState.self, from: data) else { return true }
            return state.phase != .completed
        }
    }

    private func transcribe(
        _ session: RecordingSession,
        formatting: TranscriptFormatting,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> TranscriptResult {
        let processor = processor(for: session.manifest.language)
        if !(await processor.modelsArePrepared) {
            try await processor.prepareModels(allowDownloads: false)
        }
        let artifacts = try await processor.process(session: session) { progress($0) }
        let format: TranscriptTextFormat
        switch formatting {
        case .readable: format = .readable
        case .timestamped: format = .timestamped
        case .plainText: format = .plainText
        }
        let text = artifacts.transcript.rendered(as: format)
        guard !text.isEmpty else { throw CallScribeBackendError.noTranscript }
        try Data((text + "\n").utf8).write(to: artifacts.textURL, options: .atomic)
        return TranscriptResult(text: text, textFileURL: artifacts.textURL, sessionDirectoryURL: session.directoryURL)
    }
}
