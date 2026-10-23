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
    private let captions = LiveCaptionService()
    private let azureCaptions = AzureLiveCaptionService()
    private var captionSettings = CaptionServiceSettings()
    private var captionJournal: CaptionJournal?
    private var captionsEnabled = false
    private var captionUpdate: (@Sendable (LiveCaptionUpdate) -> Void)?
    private var recordingLanguage: TranscriptionLanguage = .english
    private var captionStartTask: Task<Void, Never>?
    private var captionConfigurationGeneration = UUID()

    private func startCaptionsIfRecording() async {
        guard !Task.isCancelled, captionsEnabled, let coordinator, let captionUpdate,
              case .recording = coordinator.status else { return }
        let journal = captionJournal
        let handler: @Sendable (LiveCaptionUpdate) -> Void = { update in
            do { try journal?.receive(update) }
            catch { captionUpdate(.init(status: "Caption archive could not be saved. Audio recording continues.")) }
            captionUpdate(update)
        }
        let source: @Sendable () -> [CaptionAudioWindow] = {
            coordinator.captionAudioSnapshot(tracks: [.system])
        }
        if captionSettings.provider == .azure {
            do {
                guard let key = try AzureCredentialStore.read(), !key.isEmpty else {
                    throw CallScribeBackendError.unavailable("Add your Azure Speech key in Settings.")
                }
                try await azureCaptions.start(configuration: .init(key: key, region: captionSettings.region,
                    maximumSeconds: captionSettings.limitMinutes * 60), language: recordingLanguage, source: source, update: handler)
            } catch {
                handler(.init(status: "Azure captions unavailable: \(error.localizedDescription) Recording continues."))
            }
        } else {
            await captions.start(language: recordingLanguage, source: source, update: handler)
        }
    }

    func configureLiveCaptions(enabled: Bool, settings: CaptionServiceSettings,
                               update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async {
        let token = UUID()
        captionConfigurationGeneration = token
        captionStartTask?.cancel()
        captionsEnabled = enabled
        captionSettings = settings
        captionUpdate = update
        coordinator?.setCaptionBufferEnabled(enabled)
        await captions.stop()
        await azureCaptions.stop()
        guard captionConfigurationGeneration == token else { return }
        if enabled {
            captionStartTask = Task { [weak self] in await self?.startCaptionsIfRecording() }
        }
    }

    func prepareCaptionModels(progress: @escaping @Sendable (Double?) -> Void) async throws {
        try await captions.prepareModels { progress($0) }
    }

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
        // A readiness query must never compile or load multi-gigabyte models.
        // Loading belongs to explicit preparation or final transcription, not
        // launching a utility whose live captions may run entirely in Azure.
        guard processorLanguage == language, let processor else { return .notPrepared }
        return await processor.modelsArePrepared ? .ready : .notPrepared
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

    func startRecording(microphoneID: String?, language: TranscriptionLanguage) async throws {
        if coordinator == nil { coordinator = CaptureCoordinator(sessionStore: try sessionStore()) }
        await azureCaptions.resetSessionUsage()
        try coordinator?.startCapture(microphoneUID: microphoneID, language: language)
        processor = nil
        processorLanguage = nil
        recordingLanguage = language
        if let directory = coordinator?.sessionDirectoryURL {
            captionJournal = try? CaptionJournal(directory: directory)
        }
        coordinator?.setCaptionBufferEnabled(captionsEnabled)
        if captionsEnabled {
            // Never wait for model loading before reporting that capture started.
            captionStartTask = Task { [weak self] in await self?.startCaptionsIfRecording() }
        }
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
        let finalWindows = coordinator.captionAudioSnapshot()
        let session = try coordinator.stopCapture()
        coordinator.setCaptionBufferEnabled(false)
        captionStartTask?.cancel()
        captionStartTask = nil
        await captions.stop()
        await azureCaptions.finish(finalWindows: finalWindows)
        do { try captionJournal?.close() }
        catch { captionUpdate?(.init(status: "Caption export failed; audio is saved in Sessions.")) }
        captionJournal = nil
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
