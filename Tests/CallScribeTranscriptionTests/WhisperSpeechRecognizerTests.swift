@testable import CallScribeTranscription
import CallScribeCore
import XCTest

final class WhisperSpeechRecognizerTests: XCTestCase {
    func testManualLanguagesTranscribeInsteadOfTranslateOrDetect() {
        for language in [TranscriptionLanguage.turkish, .german] {
            let options = WhisperSpeechRecognizer.decodingOptions(for: language)
            XCTAssertEqual(options.language, language.rawValue)
            XCTAssertEqual(options.task, .transcribe)
            XCTAssertFalse(options.detectLanguage)
            XCTAssertTrue(options.wordTimestamps)
            XCTAssertTrue(options.usePrefillPrompt)
        }
    }

    func testOfflinePreparationWithMissingCacheFailsWithoutCreatingDownloadFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recognizer = WhisperSpeechRecognizer(language: .turkish, cacheRoot: root)
        do {
            try await recognizer.prepareModels(allowDownloads: false, progress: { _ in })
            XCTFail("A missing cache must not be implicitly downloaded")
        } catch let error as CallScribeTranscriptionError {
            XCTAssertEqual(error, .modelsNotPrepared)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let ready = await recognizer.isPrepared
        XCTAssertFalse(ready)
    }

    func testLocalTokenizerWithMissingFilesFailsLocally() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await LocalWhisperTokenizer.load(from: folder)
            XCTFail("Missing tokenizer must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCorruptLocalTokenizerFailsInsteadOfUsingHubFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{broken".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data("{broken".utf8).write(to: folder.appendingPathComponent("tokenizer_config.json"))
        do {
            _ = try await LocalWhisperTokenizer.load(from: folder)
            XCTFail("Corrupt tokenizer must fail locally")
        } catch { }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("tokenizer.json"), encoding: .utf8), "{broken")
    }
}
