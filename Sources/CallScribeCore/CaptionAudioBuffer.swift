import Foundation

public struct CaptionAudioWindow: Sendable {
    public let track: AudioTrack
    public let samples: [Float]
    public let endFrame: Int64

    public init(track: AudioTrack, samples: [Float], endFrame: Int64) {
        self.track = track
        self.samples = samples
        self.endFrame = endFrame
    }
}

/// Fixed-size rolling PCM storage. Captions may skip ahead under load; the
/// durable session recorder remains independent and never waits for inference.
struct CaptionAudioBuffer {
    private var storage: [Float]
    private var cursor = 0
    private var count = 0
    private(set) var endFrame: Int64?

    init(capacity: Int = 8 * 16_000) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    mutating func append(_ samples: [Float], startFrame: Int64) {
        if let endFrame, abs(startFrame - endFrame) > 1_600 {
            cursor = 0
            count = 0
            self.endFrame = nil
        }
        let overlap = max(0, Int((endFrame ?? startFrame) - startFrame))
        for sample in samples.dropFirst(min(overlap, samples.count)) {
            storage[cursor] = sample
            cursor = (cursor + 1) % storage.count
            count = min(count + 1, storage.count)
        }
        endFrame = max(endFrame ?? 0, startFrame + Int64(samples.count))
    }

    func snapshot(track: AudioTrack) -> CaptionAudioWindow? {
        guard count > 0, let endFrame else { return nil }
        let start = (cursor - count + storage.count) % storage.count
        let samples = (0..<count).map { storage[(start + $0) % storage.count] }
        return CaptionAudioWindow(track: track, samples: samples, endFrame: endFrame)
    }
}
