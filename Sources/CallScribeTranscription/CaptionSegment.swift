import CallScribeCore
import Foundation

public struct CaptionSegment: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var text: String
    public var originalText: String
    public var startTime: Double
    public var isFinal: Bool
    public var track: AudioTrack

    public init(id: String, text: String, originalText: String = "", startTime: Double,
                isFinal: Bool, track: AudioTrack = .system) {
        self.id = id
        self.text = text
        self.originalText = originalText
        self.startTime = startTime
        self.isFinal = isFinal
        self.track = track
    }
}

/// Revisions replace their own utterance. Repeated spoken sentences remain distinct.
public struct CaptionHistory: Sendable {
    public private(set) var segments: [CaptionSegment] = []
    public init() {}

    public mutating func apply(_ segment: CaptionSegment) {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            guard !segments[index].isFinal || segment.isFinal else { return }
            segments[index] = segment
        } else {
            segments.append(segment)
        }
    }
}
