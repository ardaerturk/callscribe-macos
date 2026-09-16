@testable import CallScribeCore
import XCTest

final class CaptionAudioBufferTests: XCTestCase {
    func testRollingAudioStaysBoundedAndKeepsNewestSamples() {
        var buffer = CaptionAudioBuffer(capacity: 4)
        buffer.append([1, 2, 3], startFrame: 0)
        buffer.append([4, 5, 6], startFrame: 3)
        XCTAssertEqual(buffer.snapshot(track: .system)?.samples, [3, 4, 5, 6])
        XCTAssertEqual(buffer.snapshot(track: .system)?.endFrame, 6)
    }

    func testRouteGapAndBackwardsClockResetOldCaptionAudio() {
        var buffer = CaptionAudioBuffer(capacity: 8)
        buffer.append([1, 2], startFrame: 0)
        buffer.append([3, 4], startFrame: 5_000)
        XCTAssertEqual(buffer.snapshot(track: .system)?.samples, [3, 4])
        buffer.append([5, 6], startFrame: 0)
        XCTAssertEqual(buffer.snapshot(track: .system)?.samples, [5, 6])
    }

    func testOverlappingPacketsAreNotDuplicated() {
        var buffer = CaptionAudioBuffer(capacity: 8)
        buffer.append([1, 2, 3], startFrame: 0)
        buffer.append([3, 4, 5], startFrame: 2)
        XCTAssertEqual(buffer.snapshot(track: .microphone)?.samples, [1, 2, 3, 4, 5])
    }
}
