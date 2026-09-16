@testable import CallScribeTranscription
import CallScribeCore
import XCTest

final class LiveCaptionServiceTests: XCTestCase {
    func testCaptionOptionsTranslateNonEnglishButTranscribeEnglish() {
        for language in [TranscriptionLanguage.turkish, .german] {
            let options = WhisperSpeechRecognizer.captionOptions(for: language)
            XCTAssertEqual(options.task, .translate)
            XCTAssertEqual(options.language, language.rawValue)
            XCTAssertFalse(options.detectLanguage)
            XCTAssertFalse(options.wordTimestamps)
        }
        XCTAssertEqual(WhisperSpeechRecognizer.captionOptions(for: .english).task, .transcribe)
        XCTAssertNotEqual(WhisperSpeechRecognizer.captionVariant, WhisperSpeechRecognizer.variant)
    }

    func testSilenceSuppressionAndConservativeEchoMatching() {
        XCTAssertFalse(LiveCaptionService.hasRecentSpeechEnergy([Float](repeating: 0, count: 128_000)))
        XCTAssertFalse(LiveCaptionService.hasRecentSpeechEnergy([Float](repeating: 0.1, count: 48_000)))
        XCTAssertTrue(LiveCaptionService.hasRecentSpeechEnergy([Float](repeating: 0.1, count: 96_000)))
        XCTAssertTrue(LiveCaptionService.isLikelyEcho("The report arrives on Friday", of: "The report arrives on Friday."))
        XCTAssertFalse(LiveCaptionService.isLikelyEcho("Yes", of: "Yes"))
        XCTAssertFalse(LiveCaptionService.isLikelyEcho("We disagree about the deadline", of: "The report arrives on Friday"))
    }

    func testLiveStartNeverAllowsDownloadsAndProcessesLatestSnapshot() async throws {
        let translated = expectation(description: "caption")
        let translator = CaptionTestTranslator()
        let service = LiveCaptionService(translator: translator, intervalNanoseconds: 1_000_000)
        await service.start(language: .turkish, source: {
            [.init(track: .system, samples: [Float](repeating: 0.1, count: 96_000), endFrame: 96_000)]
        }, update: { update in if update.callText == "The meeting starts tomorrow." { translated.fulfill() } })
        await fulfillment(of: [translated], timeout: 2)
        await service.stop()
        let downloads = await translator.downloadFlags
        XCTAssertEqual(downloads, [false])
        let languages = await translator.languages
        XCTAssertEqual(languages, [.turkish])
    }

    func testStopSuppressesResultAlreadyBeingTranslated() async throws {
        let started = expectation(description: "inference started")
        let late = expectation(description: "late caption must be discarded")
        late.isInverted = true
        let translator = CaptionTestTranslator(started: started)
        let service = LiveCaptionService(translator: translator, intervalNanoseconds: 1_000_000)
        await service.start(language: .german, source: {
            [.init(track: .system, samples: [Float](repeating: 0.1, count: 96_000), endFrame: 96_000)]
        }, update: { if !$0.callText.isEmpty { late.fulfill() } })
        await fulfillment(of: [started], timeout: 2)
        await service.stop()
        await translator.release()
        await fulfillment(of: [late], timeout: 0.05)
    }
}

private actor CaptionTestTranslator: EnglishCaptionTranslating {
    var downloadFlags: [Bool] = []
    var languages: [TranscriptionLanguage] = []
    let started: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation? = nil) { self.started = started }
    func prepareModels(allowDownloads: Bool, progress: @escaping ModelPreparationProgress) async throws {
        downloadFlags.append(allowDownloads)
    }
    func englishCaption(samples: [Float], language: TranscriptionLanguage) async throws -> String {
        languages.append(language)
        if let started {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        return "The meeting starts tomorrow."
    }
    func release() { continuation?.resume(); continuation = nil }
}
