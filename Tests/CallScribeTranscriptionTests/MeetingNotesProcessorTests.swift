@testable import CallScribeTranscription
import CallScribeCore
import Foundation
import XCTest

final class MeetingNotesProcessorTests: XCTestCase {
    func testSavedLanguageCannotBeSilentlyProcessedWithAnotherLanguage() async throws {
        let fixture = try makeSession(includeSystemAudio: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recognizer = FakeSpeechRecognizer()
        let processor = MeetingNotesProcessor(language: .german, speechRecognizer: recognizer,
            speakerDiarizer: FakeSpeakerDiarizer(intervals: []))
        do {
            _ = try await processor.process(session: fixture.session)
            XCTFail("Must not silently use the wrong language")
        } catch let error as CallScribeTranscriptionError {
            XCTAssertEqual(error, .languageMismatch)
        }
        let count = await recognizer.transcriptionCallCount
        XCTAssertEqual(count, 0)
    }
    func testDelayedPunctuationDoesNotMoveLastWordToNextSpeaker() {
        let result = SpeechRecognitionResult(text: "morning.", words: [
            RecognizedWord(text: "morning.", startTime: 6.96, endTime: 8.8)
        ])
        let words = TranscriptAssembler.words(from: result, source: .meetingAudio,
            chunkStart: 0, chunkDuration: 15, diarization: [
                DiarizedSpeakerInterval(speakerID: "first", startTime: 0, endTime: 7.2),
                DiarizedSpeakerInterval(speakerID: "next", startTime: 8.3, endTime: 14)
            ])
        XCTAssertEqual(words.first?.rawSpeakerID, "first")
    }

    func testProcessesSeparateTracksRemovesEchoAndWritesAllArtifacts() async throws {
        let fixture = try makeSession(includeSystemAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let recognizer = FakeSpeechRecognizer()
        let diarizer = FakeSpeakerDiarizer(intervals: [
            DiarizedSpeakerInterval(speakerID: "cluster-seven", startTime: 0, endTime: 4),
            DiarizedSpeakerInterval(speakerID: "cluster-three", startTime: 4, endTime: 10),
        ])
        let processor = MeetingNotesProcessor(
            speechRecognizer: recognizer,
            speakerDiarizer: diarizer,
            audioLoader: TrackMarkerAudioLoader()
        )

        try await processor.prepareModels()
        let artifacts = try await processor.process(session: fixture.session)

        XCTAssertEqual(artifacts.transcript.segments.map(\.speaker), [
            "Speaker 1", "Speaker 1", "You", "Speaker 2",
        ])
        XCTAssertEqual(artifacts.transcript.segments.map(\.text), [
            "Hello team.", "Good morning.", "My update.", "Next topic.",
        ])
        XCTAssertEqual(artifacts.transcript.segments.map(\.source), [
            .meetingAudio, .meetingAudio, .microphone, .meetingAudio,
        ])

        for url in [artifacts.textURL, artifacts.markdownURL, artifacts.jsonURL, artifacts.processingStateURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }

        let text = try String(contentsOf: artifacts.textURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[00:01] Speaker 1: Hello team."))
        XCTAssertFalse(text.contains("You: Hello team."), "speaker playback must not be attributed to the local user")

        let document = try makeDecoder().decode(
            MeetingTranscript.self,
            from: Data(contentsOf: artifacts.jsonURL)
        )
        XCTAssertEqual(document.sessionID, artifacts.transcript.sessionID)
        XCTAssertEqual(document.segments, artifacts.transcript.segments)

        let state = try makeDecoder().decode(
            TranscriptProcessingState.self,
            from: Data(contentsOf: artifacts.processingStateURL)
        )
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.progress, 1)
        XCTAssertEqual(Set(state.outputFiles), Set([
            TranscriptFileNames.plainText,
            TranscriptFileNames.markdown,
            TranscriptFileNames.json,
        ]))

        let recognitionCalls = await recognizer.transcriptionCallCount
        let diarizationCalls = await diarizer.diarizationCallCount
        XCTAssertEqual(recognitionCalls, 2)
        XCTAssertEqual(diarizationCalls, 1)
    }

    func testProcessingDoesNotPrepareOrDownloadModelsImplicitly() async throws {
        let fixture = try makeSession(includeSystemAudio: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let recognizer = FakeSpeechRecognizer()
        let diarizer = FakeSpeakerDiarizer(intervals: [])
        let processor = MeetingNotesProcessor(
            speechRecognizer: recognizer,
            speakerDiarizer: diarizer,
            audioLoader: TrackMarkerAudioLoader()
        )

        do {
            _ = try await processor.process(session: fixture.session)
            XCTFail("Processing should require explicit preparation")
        } catch let error as CallScribeTranscriptionError {
            XCTAssertEqual(error, .modelsNotPrepared)
        }

        let prepareCalls = await recognizer.preparationCallCount
        let transcriptionCalls = await recognizer.transcriptionCallCount
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(transcriptionCalls, 0)

        let stateURL = fixture.session.directoryURL
            .appendingPathComponent(TranscriptFileNames.processingState)
        let state = try makeDecoder().decode(
            TranscriptProcessingState.self,
            from: Data(contentsOf: stateURL)
        )
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.message?.contains("not prepared") == true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.session.directoryURL
                .appendingPathComponent(TranscriptFileNames.json).path
        ))
    }

    func testEqualWordsAtDifferentTimesAreNotTreatedAsEcho() {
        let words = [
            TimedTranscriptWord(
                text: "Yes.", source: .microphone, rawSpeakerID: "you",
                startTime: 1, endTime: 1.3, confidence: 1
            ),
            TimedTranscriptWord(
                text: "Yes.", source: .meetingAudio, rawSpeakerID: "remote",
                startTime: 5, endTime: 5.3, confidence: 1
            ),
        ]

        let transcript = TranscriptAssembler.assemble(
            words: words,
            sessionID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 0),
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(transcript.segments.map(\.speaker), ["You", "Speaker 1"])
        XCTAssertEqual(transcript.segments.map(\.text), ["Yes.", "Yes."])
    }

    func testSimultaneousDifferentWordsAndShortAgreementArePreserved() {
        let words = [
            TimedTranscriptWord(text: "Yes.", source: .microphone, rawSpeakerID: "you", startTime: 1, endTime: 1.2, confidence: 1),
            TimedTranscriptWord(text: "Yes.", source: .meetingAudio, rawSpeakerID: "remote", startTime: 1, endTime: 1.2, confidence: 1),
            TimedTranscriptWord(text: "My different point.", source: .microphone, rawSpeakerID: "you", startTime: 4, endTime: 5, confidence: 1),
            TimedTranscriptWord(text: "A separate idea.", source: .meetingAudio, rawSpeakerID: "remote", startTime: 4, endTime: 5, confidence: 1)
        ]
        let transcript = TranscriptAssembler.assemble(words: words, sessionID: UUID(), recordedAt: Date())
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.segments.filter { $0.speaker == "You" }.count, 2)
    }

    func testMissingChunkPreservesArchiveAndRecordsRetryableFailure() async throws {
        let fixture = try makeSession(includeSystemAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = try XCTUnwrap(fixture.session.audioURLs(for: .system).first)
        try FileManager.default.removeItem(at: missing)
        let processor = MeetingNotesProcessor(speechRecognizer: FakeSpeechRecognizer(),
            speakerDiarizer: FakeSpeakerDiarizer(intervals: []), audioLoader: TrackMarkerAudioLoader())
        try await processor.prepareModels()
        do {
            _ = try await processor.process(session: fixture.session)
            XCTFail("Missing audio must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid audio chunk"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.audioURLs(for: .microphone)[0].path))
        let state = try makeDecoder().decode(TranscriptProcessingState.self, from: Data(contentsOf:
            fixture.session.directoryURL.appendingPathComponent(TranscriptFileNames.processingState)))
        XCTAssertEqual(state.phase, .failed)
    }

    private func makeSession(includeSystemAudio: Bool) throws -> (root: URL, session: RecordingSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallScribeTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        let store = try SessionStore(rootURL: root)
        let recorder = try store.beginSession(chunkDurationSeconds: 60)
        recorder.append([0.25], to: .microphone, startFrame: 0)
        if includeSystemAudio {
            recorder.append([-0.25], to: .system, startFrame: 0)
        }
        return (root, try recorder.finish())
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct TrackMarkerAudioLoader: AudioSampleLoading {
    func load16kMono(from url: URL) throws -> [Float] {
        let isMicrophone = url.pathComponents.contains(AudioTrack.microphone.rawValue)
        return [Float](repeating: isMicrophone ? 0.25 : -0.25, count: 160_000)
    }
}

private actor FakeSpeechRecognizer: OfflineSpeechRecognizing {
    private(set) var isPrepared = false
    private(set) var preparationCallCount = 0
    private(set) var transcriptionCallCount = 0

    func prepareModels(allowDownloads: Bool, progress: @escaping ModelPreparationProgress) async throws {
        preparationCallCount += 1
        progress(0)
        isPrepared = true
        progress(1)
    }

    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        transcriptionCallCount += 1
        if samples.first ?? 0 > 0 {
            return SpeechRecognitionResult(
                text: "Hello team. My update.",
                words: [
                    RecognizedWord(text: "Hello", startTime: 1.0, endTime: 1.3, confidence: 0.96),
                    RecognizedWord(text: "team.", startTime: 1.4, endTime: 1.8, confidence: 0.96),
                    RecognizedWord(text: "My", startTime: 4.0, endTime: 4.2, confidence: 0.94),
                    RecognizedWord(text: "update.", startTime: 4.3, endTime: 4.8, confidence: 0.94),
                ],
                confidence: 0.95
            )
        }
        return SpeechRecognitionResult(
            text: "Hello team. Good morning. Next topic.",
            words: [
                RecognizedWord(text: "Hello", startTime: 1.05, endTime: 1.35, confidence: 0.91),
                RecognizedWord(text: "team.", startTime: 1.45, endTime: 1.85, confidence: 0.91),
                RecognizedWord(text: "Good", startTime: 2.5, endTime: 2.8, confidence: 0.92),
                RecognizedWord(text: "morning.", startTime: 2.9, endTime: 3.4, confidence: 0.92),
                RecognizedWord(text: "Next", startTime: 6.0, endTime: 6.3, confidence: 0.93),
                RecognizedWord(text: "topic.", startTime: 6.4, endTime: 6.9, confidence: 0.93),
            ],
            confidence: 0.92
        )
    }
}

private actor FakeSpeakerDiarizer: OfflineSpeakerDiarizing {
    private(set) var isPrepared = false
    private(set) var preparationCallCount = 0
    private(set) var diarizationCallCount = 0
    private let intervals: [DiarizedSpeakerInterval]

    init(intervals: [DiarizedSpeakerInterval]) {
        self.intervals = intervals
    }

    func prepareModels(progress: @escaping ModelPreparationProgress) async throws {
        preparationCallCount += 1
        progress(0)
        isPrepared = true
        progress(1)
    }

    func diarize(samples: [Float]) async throws -> [DiarizedSpeakerInterval] {
        diarizationCallCount += 1
        return intervals
    }
}
