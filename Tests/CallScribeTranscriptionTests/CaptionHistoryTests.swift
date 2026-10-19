@testable import CallScribeTranscription
import CallScribeCore
import XCTest

final class CaptionHistoryTests: XCTestCase {
    func testDraftRevisionsAndLatePartialsKeepOneFinalUtterance() {
        var history = CaptionHistory()
        history.apply(.init(id: "a", text: "Next week", startTime: 0, isFinal: false))
        history.apply(.init(id: "a", text: "Next week we meet.", startTime: 0, isFinal: true))
        history.apply(.init(id: "a", text: "Next", startTime: 0, isFinal: false))
        XCTAssertEqual(history.segments.count, 1)
        XCTAssertEqual(history.segments.first?.text, "Next week we meet.")
        XCTAssertEqual(history.segments.first?.isFinal, true)
    }

    func testRepeatedSentencesArePreservedAcrossDifferentUtterances() {
        var history = CaptionHistory()
        for id in ["a", "b"] { history.apply(.init(id: id, text: "Yes, we can.", startTime: 0, isFinal: true)) }
        XCTAssertEqual(history.segments.count, 2)
    }

    func testEmptyUpdateDoesNotClearDraft() {
        var history = CaptionHistory()
        history.apply(.init(id: "a", text: "Please continue", startTime: 0, isFinal: false))
        history.apply(.init(id: "a", text: "", startTime: 0, isFinal: true))
        XCTAssertEqual(history.segments.first?.text, "Please continue")
    }

    func testAudioCursorSendsEachSampleOnce() {
        var cursor = CaptionStreamCursor()
        XCTAssertEqual(cursor.consume(.init(track: .system, samples: [1, 2, 3], endFrame: 3)).samples, [1, 2, 3])
        XCTAssertEqual(cursor.consume(.init(track: .system, samples: [2, 3, 4, 5], endFrame: 5)).samples, [4, 5])
        XCTAssertTrue(cursor.consume(.init(track: .system, samples: [2, 3, 4, 5], endFrame: 5)).samples.isEmpty)
    }

    func testBufferOverrunAndClockResetAreExplicitGaps() {
        var cursor = CaptionStreamCursor()
        _ = cursor.consume(.init(track: .system, samples: [1, 2], endFrame: 2))
        let overrun = cursor.consume(.init(track: .system, samples: [3, 4], endFrame: 100))
        XCTAssertTrue(overrun.gap)
        XCTAssertEqual(overrun.samples, [3, 4])
        XCTAssertTrue(cursor.consume(.init(track: .system, samples: [5, 6], endFrame: 2)).gap)
    }
}
