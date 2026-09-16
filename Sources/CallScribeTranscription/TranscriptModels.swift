import CallScribeCore
import Foundation

public enum TranscriptSource: String, Codable, Hashable, Sendable {
    case microphone
    case meetingAudio = "meeting_audio"

    init(_ track: AudioTrack) {
        switch track {
        case .microphone:
            self = .microphone
        case .system:
            self = .meetingAudio
        }
    }
}

/// A word and its timing relative to the audio buffer supplied to the recognizer.
public struct RecognizedWord: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double = 1
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct SpeechRecognitionResult: Codable, Equatable, Sendable {
    public let text: String
    public let words: [RecognizedWord]
    public let confidence: Double

    public init(text: String, words: [RecognizedWord], confidence: Double = 1) {
        self.text = text
        self.words = words
        self.confidence = confidence
    }

    public static let empty = SpeechRecognitionResult(text: "", words: [], confidence: 0)
}

/// A speaker interval relative to the complete meeting-audio timeline.
public struct DiarizedSpeakerInterval: Codable, Equatable, Sendable {
    public let speakerID: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(speakerID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let speaker: String
    public let source: TranscriptSource
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let confidence: Double

    public init(
        id: String,
        speaker: String,
        source: TranscriptSource,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Double
    ) {
        self.id = id
        self.speaker = speaker
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
    }
}

public enum TranscriptTextFormat: Sendable {
    case readable
    case timestamped
    case plainText
}

public struct MeetingTranscript: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let recordedAt: Date
    public let generatedAt: Date
    public let languageCode: String
    public let segments: [TranscriptSegment]
    public let recordingNotes: [String]?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        recordedAt: Date,
        generatedAt: Date = Date(),
        languageCode: String = "en",
        segments: [TranscriptSegment],
        recordingNotes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.generatedAt = generatedAt
        self.languageCode = languageCode
        self.segments = segments
        self.recordingNotes = recordingNotes
    }

    public func rendered(as format: TranscriptTextFormat) -> String {
        let body: String
        switch format {
        case .readable:
            body = segments
                .map { "\($0.speaker): \($0.text)" }
                .joined(separator: "\n\n")
        case .timestamped:
            body = segments
                .map { "\(Self.timestamp($0.startTime)) \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
        case .plainText:
            body = segments.map(\.text).joined(separator: "\n")
        }
        let notes = recordingNotes ?? []
        return notes.isEmpty ? body : "Recording notes: " + notes.joined(separator: "; ") + "\n\n" + body
    }

    public var markdown: String {
        var lines = ["# Call transcript", ""]
        lines.append("Recorded: \(Self.iso8601String(from: recordedAt))")
        lines.append("")
        for note in recordingNotes ?? [] { lines.append("> \(note)") }
        if !(recordingNotes ?? []).isEmpty { lines.append("") }
        for segment in segments {
            lines.append("**\(Self.timestamp(segment.startTime)) \(segment.speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "[%02d:%02d:%02d]", hours, minutes, remainingSeconds)
        }
        return String(format: "[%02d:%02d]", minutes, remainingSeconds)
    }
}

public enum TranscriptProcessingPhase: String, Codable, Equatable, Sendable {
    case validating
    case loadingAudio = "loading_audio"
    case diarizing
    case transcribing
    case writing
    case completed
    case failed
}

public struct TranscriptProcessingState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let phase: TranscriptProcessingPhase
    public let progress: Double
    public let updatedAt: Date
    public let message: String?
    public let outputFiles: [String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        phase: TranscriptProcessingPhase,
        progress: Double,
        updatedAt: Date = Date(),
        message: String? = nil,
        outputFiles: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.phase = phase
        self.progress = min(1, max(0, progress))
        self.updatedAt = updatedAt
        self.message = message
        self.outputFiles = outputFiles
    }
}

public struct TranscriptArtifacts: Sendable {
    public let transcript: MeetingTranscript
    public let textURL: URL
    public let markdownURL: URL
    public let jsonURL: URL
    public let processingStateURL: URL

    public init(
        transcript: MeetingTranscript,
        textURL: URL,
        markdownURL: URL,
        jsonURL: URL,
        processingStateURL: URL
    ) {
        self.transcript = transcript
        self.textURL = textURL
        self.markdownURL = markdownURL
        self.jsonURL = jsonURL
        self.processingStateURL = processingStateURL
    }
}

public enum CallScribeTranscriptionError: LocalizedError, Equatable {
    case operationInProgress
    case noSpeech
    case modelsNotPrepared
    case sessionStillRecording
    case noAudio
    case invalidChunk(String)
    case audioTooLarge

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another model or transcript operation is in progress."
        case .noSpeech:
            return "No speech was recognized. The audio is retained for retry."
        case .modelsNotPrepared:
            return "Offline transcription models are not prepared. Prepare them before processing a recording."
        case .sessionStillRecording:
            return "The recording is still active. Stop or recover it before transcription."
        case .noAudio:
            return "The session contains no finalized audio to transcribe."
        case .invalidChunk(let detail):
            return "The recording contains an invalid audio chunk: \(detail)"
        case .audioTooLarge:
            return "The recording timeline is too large to process safely."
        }
    }
}
