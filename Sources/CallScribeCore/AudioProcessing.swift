import AudioToolbox
import Foundation

/// A copied block of PCM input. Capture callbacks create these blocks quickly
/// and hand them to the coordinator's serial processing queue; no file I/O is
/// performed on a real-time Core Audio thread.
struct CapturedPCMBlock: Sendable {
    let startNanoseconds: UInt64
    let sampleRate: Double
    let channels: [[Float]]

    var frameCount: Int { channels.map(\.count).min() ?? 0 }
}

struct AlignedPCMBlock: Equatable, Sendable {
    let startFrame: Int64
    let samples: [Float]
}

/// Maps independently-clocked microphone and system callbacks onto one 16 kHz
/// grid. Using the timestamp of the first source frame avoids cumulative drift
/// from rounding every callback's duration in isolation.
struct MonotonicAudioTimeline: Sendable {
    let originNanoseconds: UInt64
    let sampleRate: Int

    init(originNanoseconds: UInt64, sampleRate: Int = 16_000) {
        self.originNanoseconds = originNanoseconds
        self.sampleRate = sampleRate
    }

    func exactFrame(at nanoseconds: UInt64) -> Double {
        let delta = nanoseconds >= originNanoseconds ? nanoseconds - originNanoseconds : 0
        return Double(delta) * Double(sampleRate) / 1_000_000_000
    }

    func frame(at nanoseconds: UInt64) -> Int64 {
        Int64(exactFrame(at: nanoseconds).rounded(.down))
    }

    /// Downmixes all available channels with equal gain and linearly resamples
    /// onto the session grid. Output intervals are half-open, so consecutive
    /// timestamped input blocks cannot both claim the same 16 kHz frame.
    func convert(_ block: CapturedPCMBlock) throws -> AlignedPCMBlock {
        guard block.sampleRate.isFinite, block.sampleRate > 0 else {
            throw CallScribeCoreError.invalidAudioFormat("input sample rate must be positive")
        }
        let inputFrames = block.frameCount
        guard inputFrames > 0, !block.channels.isEmpty else {
            return AlignedPCMBlock(startFrame: frame(at: block.startNanoseconds), samples: [])
        }

        var mono = [Float](repeating: 0, count: inputFrames)
        let gain = Float(1) / Float(block.channels.count)
        for channel in block.channels {
            for index in 0..<inputFrames {
                let value = channel[index]
                mono[index] += (value.isFinite ? value : 0) * gain
            }
        }

        let exactStart = exactFrame(at: block.startNanoseconds)
        let exactEnd = exactStart + Double(inputFrames) * Double(sampleRate) / block.sampleRate
        let outputStart = Int64(exactStart.rounded(.up))
        let outputEnd = Int64(exactEnd.rounded(.up))
        guard outputEnd > outputStart else {
            return AlignedPCMBlock(startFrame: outputStart, samples: [])
        }

        let sourceFramesPerOutputFrame = block.sampleRate / Double(sampleRate)
        var output = [Float]()
        output.reserveCapacity(Int(outputEnd - outputStart))
        for outputFrame in outputStart..<outputEnd {
            let sourcePosition = (Double(outputFrame) - exactStart) * sourceFramesPerOutputFrame
            let lower = min(inputFrames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(inputFrames - 1, lower + 1)
            let fraction = Float(min(1, max(0, sourcePosition - Double(lower))))
            output.append(mono[lower] + (mono[upper] - mono[lower]) * fraction)
        }
        return AlignedPCMBlock(startFrame: outputStart, samples: output)
    }
}

protocol MonotonicNanosecondClock: Sendable {
    func now() -> UInt64
}

struct AudioHostClock: MonotonicNanosecondClock {
    func now() -> UInt64 {
        AudioConvertHostTimeToNanos(mach_absolute_time())
    }

    static func nanoseconds(forHostTime hostTime: UInt64) -> UInt64 {
        AudioConvertHostTimeToNanos(hostTime)
    }
}

struct CaptureHealthTracker: Sendable {
    private(set) var lastActivity: [AudioTrack: UInt64] = [:]
    private(set) var sleeping = false

    mutating func started(_ track: AudioTrack, at now: UInt64) {
        lastActivity[track] = now
    }

    mutating func observed(_ track: AudioTrack, at now: UInt64) {
        guard !sleeping else { return }
        lastActivity[track] = max(lastActivity[track] ?? 0, now)
    }

    mutating func setSleeping(_ value: Bool) {
        sleeping = value
    }

    mutating func remove(_ track: AudioTrack) {
        lastActivity.removeValue(forKey: track)
    }

    func stalledTracks(at now: UInt64, timeoutNanoseconds: UInt64) -> [AudioTrack] {
        guard !sleeping else { return [] }
        return lastActivity.compactMap { track, last in
            now >= last && now - last >= timeoutNanoseconds ? track : nil
        }
        .sorted { $0.rawValue < $1.rawValue }
    }
}
