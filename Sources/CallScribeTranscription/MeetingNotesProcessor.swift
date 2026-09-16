import CallScribeCore
import Foundation
import FluidAudio
import AVFoundation

public enum TranscriptFileNames {
    public static let plainText = "transcript.txt"
    public static let markdown = "transcript.md"
    public static let json = "transcript.json"
    public static let processingState = "processing-state.json"
}

/// Processes completed CallScribeCore sessions into durable, local transcript
/// artifacts. Calls are serialized so one model set cannot be used by multiple
/// session jobs at the same time.
public actor MeetingNotesProcessor {
    public typealias ProcessingProgress = @Sendable (Double) -> Void

    private let speechRecognizer: any OfflineSpeechRecognizing
    private let speakerDiarizer: any OfflineSpeakerDiarizing
    private let audioLoader: any AudioSampleLoading
    private let fileManager: FileManager
    private var busy = false
    public let language: TranscriptionLanguage

    public init(
        language: TranscriptionLanguage = .english,
        speechRecognizer: (any OfflineSpeechRecognizing)? = nil,
        speakerDiarizer: any OfflineSpeakerDiarizing = FluidAudioSpeakerDiarizer(),
        audioLoader: any AudioSampleLoading = FluidAudioSampleLoader(),
        fileManager: FileManager = .default
    ) {
        self.language = language
        self.speechRecognizer = speechRecognizer ?? (language == .english
            ? FluidAudioSpeechRecognizer() as any OfflineSpeechRecognizing
            : WhisperSpeechRecognizer(language: language) as any OfflineSpeechRecognizing)
        self.speakerDiarizer = speakerDiarizer
        self.audioLoader = audioLoader
        self.fileManager = fileManager
        ModelHub.offlineMode = true
    }

    public var modelsArePrepared: Bool {
        get async {
            let speechReady = await speechRecognizer.isPrepared
            let diarizerReady = await speakerDiarizer.isPrepared
            return speechReady && diarizerReady
        }
    }

    /// Downloads or loads both model families. This is deliberately separate
    /// from `process`; processing fails clearly if preparation was skipped.
    public func prepareModels(
        allowDownloads: Bool = true,
        progress: @escaping ModelPreparationProgress = { _ in }
    ) async throws {
        guard !busy else { throw CallScribeTranscriptionError.operationInProgress }
        busy = true
        ModelHub.offlineMode = !allowDownloads
        defer { ModelHub.offlineMode = true; busy = false }
        progress(0)
        try await speechRecognizer.prepareModels(allowDownloads: allowDownloads) { value in
            progress(value * 0.6)
        }
        if !(await speakerDiarizer.isPrepared) {
            try await speakerDiarizer.prepareModels { value in
                progress(0.6 + value * 0.4)
            }
        }
        progress(1)
    }

    @discardableResult
    public func process(
        session: RecordingSession,
        progress: @escaping ProcessingProgress = { _ in }
    ) async throws -> TranscriptArtifacts {
        guard !busy else { throw CallScribeTranscriptionError.operationInProgress }
        busy = true
        defer { busy = false }
        let stateURL = session.directoryURL.appendingPathComponent(TranscriptFileNames.processingState)
        var currentProgress = 0.0

        do {
            try writeState(
                sessionID: session.id,
                phase: .validating,
                progress: currentProgress,
                to: stateURL
            )
            try validate(session)
            let speechReady = await speechRecognizer.isPrepared
            let diarizerReady = await speakerDiarizer.isPrepared
            guard speechReady, diarizerReady else {
                throw CallScribeTranscriptionError.modelsNotPrepared
            }

            currentProgress = 0.05
            progress(currentProgress)
            try writeState(
                sessionID: session.id,
                phase: .loadingAudio,
                progress: currentProgress,
                to: stateURL
            )
            let chunks = try loadChunks(from: session)
            guard chunks.contains(where: { $0.frameCount > 0 }) else {
                throw CallScribeTranscriptionError.noAudio
            }

            let meetingChunks = chunks.filter { $0.track == .system }
            var diarization: [DiarizedSpeakerInterval] = []
            let timelineURL = session.directoryURL.appendingPathComponent(".speaker-timeline-\(UUID().uuidString).caf")
            defer { try? fileManager.removeItem(at: timelineURL) }
            if !meetingChunks.isEmpty {
                currentProgress = 0.14
                progress(currentProgress)
                try writeState(
                    sessionID: session.id,
                    phase: .diarizing,
                    progress: currentProgress,
                    to: stateURL
                )
                try writeMeetingTimeline(meetingChunks, session: session, to: timelineURL)
                diarization = try await speakerDiarizer.diarize(file: timelineURL)
            }

            currentProgress = 0.32
            progress(currentProgress)
            try writeState(
                sessionID: session.id,
                phase: .transcribing,
                progress: currentProgress,
                to: stateURL
            )

            var words: [TimedTranscriptWord] = []
            for (index, metadata) in chunks.enumerated() {
                let chunk = try loadChunk(metadata, from: session)
                let recognized = try await speechRecognizer.transcribe(samples: chunk.samples)
                words.append(contentsOf: TranscriptAssembler.words(
                    from: recognized,
                    source: TranscriptSource(chunk.metadata.track),
                    chunkStart: chunk.metadata.startTime,
                    chunkDuration: chunk.duration,
                    diarization: diarization
                ))
                let completedFraction = Double(index + 1) / Double(chunks.count)
                currentProgress = 0.32 + completedFraction * 0.58
                progress(currentProgress)
            }

            let transcript = TranscriptAssembler.assemble(
                words: words,
                sessionID: session.id,
                recordedAt: session.manifest.createdAt,
                recordingNotes: Array(Set(session.manifest.events.filter {
                    [.warning, .sleep, .captureStalled, .captureRestartFailed, .recoveredAfterInterruption].contains($0.kind)
                }.map(\.message))).sorted()
            )
            guard !transcript.segments.isEmpty else { throw CallScribeTranscriptionError.noSpeech }

            currentProgress = 0.94
            progress(currentProgress)
            try writeState(
                sessionID: session.id,
                phase: .writing,
                progress: currentProgress,
                to: stateURL
            )
            let artifacts = try writeTranscript(transcript, to: session.directoryURL, stateURL: stateURL)

            currentProgress = 1
            try writeState(
                sessionID: session.id,
                phase: .completed,
                progress: currentProgress,
                outputFiles: [
                    TranscriptFileNames.plainText,
                    TranscriptFileNames.markdown,
                    TranscriptFileNames.json,
                ],
                to: stateURL
            )
            progress(currentProgress)
            return artifacts
        } catch {
            try? writeState(
                sessionID: session.id,
                phase: .failed,
                progress: currentProgress,
                message: error.localizedDescription,
                to: stateURL
            )
            throw error
        }
    }

    private struct LoadedChunk {
        let metadata: AudioChunkMetadata
        let samples: [Float]

        var duration: TimeInterval {
            Double(samples.count) / 16_000
        }
    }

    private func validate(_ session: RecordingSession) throws {
        guard session.manifest.language == language else {
            throw CallScribeTranscriptionError.languageMismatch
        }
        guard session.manifest.state != .recording else {
            throw CallScribeTranscriptionError.sessionStillRecording
        }
        guard !session.manifest.chunks.isEmpty else {
            throw CallScribeTranscriptionError.noAudio
        }
        guard session.manifest.sampleRate > 0 else {
            throw CallScribeTranscriptionError.invalidChunk("session sample rate is not positive")
        }
        guard session.manifest.chunks.allSatisfy(\.finalized) else {
            throw CallScribeTranscriptionError.invalidChunk("an audio file was not finalized")
        }
    }

    private func loadChunks(from session: RecordingSession) throws -> [AudioChunkMetadata] {
        let directory = session.directoryURL.standardizedFileURL
        let directoryPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"

        return try session.manifest.chunks
            .sorted(by: chunkSort)
            .map { metadata in
                guard metadata.startFrame >= 0,
                      metadata.frameCount >= 0,
                      metadata.sampleRate > 0 else {
                    throw CallScribeTranscriptionError.invalidChunk(metadata.relativePath)
                }
                let url = directory.appendingPathComponent(metadata.relativePath).standardizedFileURL
                guard url.path.hasPrefix(directoryPrefix),
                      fileManager.fileExists(atPath: url.path) else {
                    throw CallScribeTranscriptionError.invalidChunk(metadata.relativePath)
                }
                return metadata
            }
    }

    private func loadChunk(_ metadata: AudioChunkMetadata, from session: RecordingSession) throws -> LoadedChunk {
        let url = session.directoryURL.appendingPathComponent(metadata.relativePath)
        return LoadedChunk(metadata: metadata, samples: try audioLoader.load16kMono(from: url))
    }

    /// Keep only one recording chunk in memory. FluidAudio reads the resulting
    /// CAF through its disk-backed source during whole-meeting diarization.
    private func writeMeetingTimeline(_ chunks: [AudioChunkMetadata], session: RecordingSession, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var position: Int64 = 0
        func append(_ samples: ArraySlice<Float>) throws {
            guard !samples.isEmpty else { return }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        }
        let silence = [Float](repeating: 0, count: 16_000)
        for metadata in chunks {
            let chunk = try loadChunk(metadata, from: session)
            let seconds = metadata.startTime
            guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else {
                throw CallScribeTranscriptionError.audioTooLarge
            }
            let start = Int64((seconds * 16_000).rounded())
            while position < start {
                let count = Int(min(start - position, 16_000))
                try append(silence.prefix(count))
                position += Int64(count)
            }
            let trim = Int(min(Int64(chunk.samples.count), max(0, position - start)))
            try append(chunk.samples.dropFirst(trim))
            position += Int64(chunk.samples.count - trim)
        }
    }

    private func writeTranscript(
        _ transcript: MeetingTranscript,
        to directory: URL,
        stateURL: URL
    ) throws -> TranscriptArtifacts {
        let textURL = directory.appendingPathComponent(TranscriptFileNames.plainText)
        let markdownURL = directory.appendingPathComponent(TranscriptFileNames.markdown)
        let jsonURL = directory.appendingPathComponent(TranscriptFileNames.json)

        let text = transcript.rendered(as: .timestamped)
        try writeAtomically(Data((text.isEmpty ? "" : text + "\n").utf8), to: textURL)
        try writeAtomically(Data(transcript.markdown.utf8), to: markdownURL)
        try writeAtomically(try makeEncoder().encode(transcript), to: jsonURL)

        return TranscriptArtifacts(
            transcript: transcript,
            textURL: textURL,
            markdownURL: markdownURL,
            jsonURL: jsonURL,
            processingStateURL: stateURL
        )
    }

    private func writeState(
        sessionID: UUID,
        phase: TranscriptProcessingPhase,
        progress: Double,
        message: String? = nil,
        outputFiles: [String] = [],
        to url: URL
    ) throws {
        let state = TranscriptProcessingState(
            sessionID: sessionID,
            phase: phase,
            progress: progress,
            message: message,
            outputFiles: outputFiles
        )
        try writeAtomically(try makeEncoder().encode(state), to: url)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func chunkSort(_ lhs: AudioChunkMetadata, _ rhs: AudioChunkMetadata) -> Bool {
        if lhs.startFrame != rhs.startFrame { return lhs.startFrame < rhs.startFrame }
        if lhs.track != rhs.track { return lhs.track == .microphone }
        return lhs.index < rhs.index
    }
}
