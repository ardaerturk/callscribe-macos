import Foundation

public enum TranscriptionLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case turkish = "tr"
    case german = "de"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe (Turkish)"
        case .german: return "Deutsch (German)"
        }
    }
}

public enum AudioTrack: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone = "mic"
    case system
}

public enum RecordingSessionState: String, Codable, Hashable, Sendable {
    case recording
    case complete
    case interrupted
    case failed
}

public struct AudioChunkMetadata: Codable, Hashable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let track: AudioTrack
    public let index: Int
    public let relativePath: String
    public let startFrame: Int64
    public let frameCount: Int64
    public let sampleRate: Int
    public let finalized: Bool
    public let createdAt: Date

    public var endFrame: Int64 { startFrame + frameCount }
    public var startTime: TimeInterval { Double(startFrame) / Double(sampleRate) }
    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
}

public struct CaptureEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case started
        case stopped
        case microphonePaused
        case microphoneResumed
        case routeChanged
        case captureStalled
        case captureRestarted
        case captureRestartFailed
        case gapInserted
        case sleep
        case wake
        case warning
        case recoveredAfterInterruption
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let track: AudioTrack?
    public let frame: Int64?
    public let frameCount: Int64?
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        track: AudioTrack? = nil,
        frame: Int64? = nil,
        frameCount: Int64? = nil,
        message: String
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.track = track
        self.frame = frame
        self.frameCount = frameCount
        self.message = message
    }
}

public struct RecordingSessionManifest: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var stoppedAt: Date?
    public var state: RecordingSessionState
    public let sampleRate: Int
    public var microphoneUID: String?
    public var microphoneName: String?
    public var chunks: [AudioChunkMetadata]
    public var events: [CaptureEvent]
    public var failureReason: String?
    // Optional for backward compatibility with pre-language archives.
    public var transcriptionLanguage: TranscriptionLanguage?
    public var language: TranscriptionLanguage { transcriptionLanguage ?? .english }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        state: RecordingSessionState = .recording,
        sampleRate: Int = 16_000,
        microphoneUID: String? = nil,
        microphoneName: String? = nil,
        language: TranscriptionLanguage = .english
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.stoppedAt = nil
        self.state = state
        self.sampleRate = sampleRate
        self.microphoneUID = microphoneUID
        self.microphoneName = microphoneName
        self.chunks = []
        self.events = []
        self.failureReason = nil
        self.transcriptionLanguage = language
    }
}

public struct RecordingSession: Identifiable, Hashable, Sendable {
    public let directoryURL: URL
    public let manifest: RecordingSessionManifest

    public var id: UUID { manifest.id }
    public var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }

    public func audioURLs(for track: AudioTrack) -> [URL] {
        manifest.chunks
            .filter { $0.track == track }
            .sorted { ($0.startFrame, $0.index) < ($1.startFrame, $1.index) }
            .map { directoryURL.appendingPathComponent($0.relativePath) }
    }
}

public enum CaptureStatus: Equatable, Sendable {
    case idle
    case starting
    case recording(sessionID: UUID, microphonePaused: Bool, warnings: [String])
    case stopping(sessionID: UUID)
    case failed(message: String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

public enum CallScribeCoreError: LocalizedError, Equatable {
    case captureAlreadyRunning
    case captureNotRunning
    case microphonePermissionDenied
    case inputDeviceUnavailable(String)
    case noCaptureSourceAvailable([String])
    case invalidAudioFormat(String)
    case coreAudioFailure(operation: String, status: OSStatus)
    case sessionCorrupt(String)

    public var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning:
            return "A recording is already in progress."
        case .captureNotRunning:
            return "There is no recording in progress."
        case .microphonePermissionDenied:
            return "Microphone permission was denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .inputDeviceUnavailable(let identifier):
            return "The selected microphone is not available (\(identifier))."
        case .noCaptureSourceAvailable(let reasons):
            return "Neither microphone nor system audio could start: \(reasons.joined(separator: "; "))"
        case .invalidAudioFormat(let detail):
            return "Invalid audio format: \(detail)"
        case .coreAudioFailure(let operation, let status):
            return "\(operation) failed (Core Audio status \(status))."
        case .sessionCorrupt(let detail):
            return "The recording session is damaged: \(detail)"
        }
    }
}
