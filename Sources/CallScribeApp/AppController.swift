import AppKit
import AVFoundation
import Combine
import Foundation
import CallScribeCore

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var state: RecordingState = .recovering
    @Published private(set) var pendingCount = 0
    @Published private(set) var captureWarning: String?
    @Published private(set) var modelReadiness: ModelReadiness = .notPrepared
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var lastSessionDirectoryURL: URL?
    @Published private(set) var statusDetail = "Right-click the microphone for options."
    @Published private(set) var recordingStartedAt: Date?

    let settings: AppSettings
    let audioDevices: AudioDeviceCatalog

    private let backend: CallScribeBackend
    private var healthTask: Task<Void, Never>?
    private let requestMicrophoneAccess: () async -> Bool
    private let clipboardWriter: ((String) -> Void)?

    init(
        backend: CallScribeBackend? = nil,
        settings: AppSettings? = nil,
        audioDevices: AudioDeviceCatalog? = nil,
        requestMicrophoneAccess: (() async -> Bool)? = nil,
        clipboardWriter: ((String) -> Void)? = nil
    ) {
        self.backend = backend ?? CoreBackendAdapter()
        self.settings = settings ?? AppSettings()
        self.audioDevices = audioDevices ?? AudioDeviceCatalog()
        self.requestMicrophoneAccess = requestMicrophoneAccess ?? { await Self.requestMicrophoneAccessIfNeeded() }
        self.clipboardWriter = clipboardWriter
    }

    var sessionsDirectoryURL: URL { backend.sessionsDirectoryURL }

    var canChangeLanguage: Bool {
        if case .downloading = modelReadiness { return false }
        return state.canStartOrStop && !state.isCapturing
    }

    func selectLanguage(_ language: TranscriptionLanguage) {
        guard canChangeLanguage, language != settings.language else { return }
        settings.language = language
        state = .recovering
        modelReadiness = .notPrepared
        statusDetail = "Checking local models for \(language.title)..."
        Task {
            modelReadiness = await backend.currentModelReadiness(language: language)
            state = .idle
            statusDetail = modelReadiness == .ready
                ? "Ready to record in \(language.title)."
                : "Choose Prepare Offline Models once for \(language.title). Audio can still be saved before setup finishes."
        }
    }

    func bootstrap() {
        Task {
            statusDetail = "Checking saved sessions and local models..."
            do {
                pendingCount = try await backend.repairArchive()
                if let last = try await backend.latestTranscript() {
                    lastTranscriptURL = last.textFileURL
                    lastSessionDirectoryURL = last.sessionDirectoryURL
                }
                modelReadiness = await backend.currentModelReadiness(language: settings.language)
                state = .idle
                statusDetail = modelReadiness == .ready
                    ? "Ready. Left-click the microphone to record."
                    : "Recording is ready. Prepare offline models to create transcripts."
            } catch {
                fail(error, prefix: "Recovery did not complete")
            }
        }
    }

    func toggleRecording() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording, .microphonePaused:
            stopRecording()
        case .starting, .recovering, .processing:
            NSSound.beep()
        }
    }

    func startRecording() {
        guard state.canStartOrStop else { return }
        if case .downloading = modelReadiness { return }
        state = .starting
        captureWarning = nil
        Task {
            do {
                let allowed = await requestMicrophoneAccess()
                guard allowed else {
                    throw CallScribeBackendError.unavailable(
                        "Microphone access is off. Enable CallScribe in System Settings > Privacy & Security > Microphone."
                    )
                }
                try await backend.startRecording(microphoneID: settings.selectedMicrophoneID, language: settings.language)
                state = .recording
                recordingStartedAt = Date()
                statusDetail = "Saving microphone and call audio locally."
                healthTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self, self.state.isCapturing else { return }
                        self.captureWarning = await self.backend.recordingWarning()
                    }
                }
            } catch {
                fail(error, prefix: "Recording could not start")
            }
        }
    }

    func stopRecording() {
        guard state == .recording || state == .microphonePaused else { return }
        healthTask?.cancel()
        healthTask = nil
        state = .processing(progress: nil)
        statusDetail = "Audio is safe in the session archive. Creating the transcript..."

        Task {
            do {
                let result = try await backend.stopAndTranscribe(
                    formatting: settings.transcriptFormatting,
                    keepAudio: settings.keepRecordingPolicy,
                    progress: { [weak self] progress in
                        Task { @MainActor in self?.state = .processing(progress: progress) }
                    }
                )
                recordingStartedAt = nil
                acceptTranscript(result, message: "Transcript copied to the clipboard.")
            } catch {
                recordingStartedAt = nil
                pendingCount = (try? await backend.repairArchive()) ?? pendingCount
                fail(error, prefix: "Transcription did not complete")
            }
        }
    }

    func toggleMicrophonePause() {
        let pause: Bool
        switch state {
        case .recording:
            pause = true
        case .microphonePaused:
            pause = false
        default:
            return
        }

        Task {
            do {
                try await backend.setMicrophonePaused(pause)
                state = pause ? .microphonePaused : .recording
                statusDetail = pause
                    ? "Call audio continues; your independent microphone track is paused."
                    : "Microphone capture resumed."
            } catch {
                captureWarning = error.localizedDescription
            }
        }
    }

    func prepareModels() {
        guard state.canStartOrStop, !state.isCapturing else { return }
        guard case .downloading = modelReadiness else {
            modelReadiness = .downloading(progress: nil)
            statusDetail = "Downloading the offline speech and speaker models..."
            Task {
                do {
                    try await backend.prepareModels(language: settings.language) { [weak self] progress in
                        Task { @MainActor in
                            self?.modelReadiness = .downloading(progress: progress)
                        }
                    }
                    modelReadiness = .ready
                    if case .error = state { state = .idle }
                    statusDetail = "Offline models are ready. No internet is needed during calls."
                } catch {
                    modelReadiness = .failed(error.localizedDescription)
                    fail(error, prefix: "Model preparation failed")
                }
            }
            return
        }
    }

    func retryPending() {
        guard state.canStartOrStop, !state.isCapturing, modelReadiness == .ready else { return }
        state = .processing(progress: nil)
        Task {
            do {
                let result = try await backend.recoverInterruptedSession(
                    formatting: settings.transcriptFormatting,
                    keepAudio: settings.keepRecordingPolicy,
                    progress: { [weak self] value in
                        Task { @MainActor in self?.state = .processing(progress: value) }
                    }
                )
                pendingCount = try await backend.repairArchive()
                if let result { acceptTranscript(result, message: "Recovered transcript copied.") }
                else { state = .idle; statusDetail = "No unfinished transcripts." }
            } catch {
                pendingCount = (try? await backend.repairArchive()) ?? pendingCount
                fail(error, prefix: "Retry did not complete")
            }
        }
    }

    @discardableResult
    func copyLastTranscript() -> Bool {
        guard let url = lastTranscriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            NSSound.beep()
            statusDetail = "There is no completed transcript to copy yet."
            return false
        }
        copyToPasteboard(text)
        statusDetail = "Transcript copied to the clipboard."
        return true
    }

    func openLastTranscript() {
        guard let lastTranscriptURL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(lastTranscriptURL)
    }

    func openSessionsDirectory() {
        try? FileManager.default.createDirectory(
            at: sessionsDirectoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(sessionsDirectoryURL)
    }

    private func acceptTranscript(_ result: TranscriptResult, message: String) {
        lastTranscriptURL = result.textFileURL
        lastSessionDirectoryURL = result.sessionDirectoryURL
        copyToPasteboard(result.text)
        state = .idle
        statusDetail = message
    }

    private func copyToPasteboard(_ text: String) {
        if let clipboardWriter { clipboardWriter(text); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func fail(_ error: Error, prefix: String) {
        let message = error.localizedDescription
        state = .error(message: message)
        statusDetail = "\(prefix): \(message) Audio already written remains in Sessions."
    }

    private static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
