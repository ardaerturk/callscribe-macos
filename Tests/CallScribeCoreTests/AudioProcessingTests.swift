@testable import CallScribeCore
import CoreAudio
import XCTest
import AVFoundation

final class AudioProcessingTests: XCTestCase {
    func testInterleavedMicrophoneSamplesAreCopiedIntoSeparateChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let values: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        for (index, value) in values.enumerated() { buffer.floatChannelData![0][index] = value }
        XCTAssertEqual(AVAudioEngineMicrophoneSource.copyChannels(from: buffer), [[0.1, 0.3, 0.5], [0.2, 0.4, 0.6]])
    }
    func testStereoDownmixAndFortyEightToSixteenKResample() throws {
        let timeline = MonotonicAudioTimeline(originNanoseconds: 1_000_000_000)
        let block = CapturedPCMBlock(
            startNanoseconds: 1_000_000_000,
            sampleRate: 48_000,
            channels: [
                [0.0, 0.1, 0.2, 0.3, 0.4, 0.5],
                [0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
            ]
        )

        let output = try timeline.convert(block)

        XCTAssertEqual(output.startFrame, 0)
        XCTAssertEqual(output.samples.count, 2)
        XCTAssertEqual(output.samples[0], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(output.samples[1], 0.4, accuracy: 0.000_001)
    }

    func testFractionalBlockBoundariesClaimEachOutputFrameOnce() throws {
        let origin: UInt64 = 10_000_000_000
        let timeline = MonotonicAudioTimeline(originNanoseconds: origin)
        let first = CapturedPCMBlock(
            startNanoseconds: origin + 31_250,
            sampleRate: 48_000,
            channels: [[0, 0.5, 1]]
        )
        let second = CapturedPCMBlock(
            startNanoseconds: origin + 93_750,
            sampleRate: 48_000,
            channels: [[1, 0.5, 0]]
        )

        let firstOutput = try timeline.convert(first)
        let secondOutput = try timeline.convert(second)

        XCTAssertEqual(firstOutput.startFrame, 1)
        XCTAssertEqual(firstOutput.samples.count, 1)
        XCTAssertEqual(secondOutput.startFrame, 2)
        XCTAssertEqual(secondOutput.samples.count, 1)
        XCTAssertEqual(firstOutput.startFrame + Int64(firstOutput.samples.count), secondOutput.startFrame)
    }

    func testTimelineClampsPreOriginTimestampWithoutNegativeFrames() throws {
        let timeline = MonotonicAudioTimeline(originNanoseconds: 1_000)
        let output = try timeline.convert(CapturedPCMBlock(
            startNanoseconds: 500,
            sampleRate: 16_000,
            channels: [[0.25, 0.5]]
        ))

        XCTAssertEqual(output.startFrame, 0)
        XCTAssertEqual(output.samples, [0.25, 0.5])
    }

    func testHealthTrackerIsMonotonicAndSuppressesSleepStalls() {
        var health = CaptureHealthTracker()
        health.started(.microphone, at: 100)
        health.observed(.microphone, at: 90)
        XCTAssertEqual(health.stalledTracks(at: 149, timeoutNanoseconds: 50), [])
        XCTAssertEqual(health.stalledTracks(at: 150, timeoutNanoseconds: 50), [.microphone])

        health.setSleeping(true)
        XCTAssertEqual(health.stalledTracks(at: 10_000, timeoutNanoseconds: 50), [])
        health.setSleeping(false)
        health.observed(.microphone, at: 10_000)
        XCTAssertEqual(health.stalledTracks(at: 10_049, timeoutNanoseconds: 50), [])
    }

    @available(macOS 14.2, *)
    func testGlobalTapDescriptionExcludesOwnProcessAndNeverMutesPlayback() {
        let processID: AudioObjectID = 42
        let description = CoreAudioSystemSource.makeTapDescription(excludingProcessID: processID)

        XCTAssertEqual(description.processes, [processID])
        XCTAssertTrue(description.isExclusive)
        XCTAssertTrue(description.isPrivate)
        XCTAssertEqual(description.muteBehavior, .unmuted)
        XCTAssertEqual(CoreAudioSystemSource.makeTapDescription(excludingProcessID: kAudioObjectUnknown).processes, [])

        let aggregate = CoreAudioSystemSource.makeAggregateDescription(
            tapUID: description.uuid.uuidString,
            aggregateUID: "test.aggregate"
        )
        XCTAssertEqual(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
        let taps = aggregate[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, description.uuid.uuidString)
    }
}
