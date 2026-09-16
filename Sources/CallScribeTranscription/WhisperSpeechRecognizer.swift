import ArgmaxCore
import CallScribeCore
import Foundation
import WhisperKit

/// One multilingual download shared by Turkish and German. The English path
/// retains Parakeet. No capture hardware is opened by this recognizer.
public actor WhisperSpeechRecognizer: OfflineSpeechRecognizing {
    public static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let captionVariant = "openai_whisper-small_216MB"
    private let language: TranscriptionLanguage
    private let cacheRoot: URL
    private var manager: WhisperKit?
    private let forLiveTranslation: Bool
    private var preparing = false
    private var captionBusy = false

    public init(language: TranscriptionLanguage, cacheRoot: URL? = nil, forLiveTranslation: Bool = false) {
        self.language = language
        self.forLiveTranslation = forLiveTranslation
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallScribe/Models/Whisper", isDirectory: true)
    }

    public var isPrepared: Bool { manager != nil }

    public func prepareModels(allowDownloads: Bool, progress: @escaping ModelPreparationProgress) async throws {
        if manager != nil { progress(1); return }
        guard !preparing else { throw CallScribeTranscriptionError.operationInProgress }
        preparing = true
        defer { preparing = false }
        let hub = HubApiWrapper(downloadBase: cacheRoot)
        let variant = forLiveTranslation ? Self.captionVariant : Self.variant
        let tokenizerRepo = forLiveTranslation ? "openai/whisper-small" : "openai/whisper-large-v3"
        let modelFolder = hub.localRepoLocation(.init(id: "argmaxinc/whisperkit-coreml"))
            .appendingPathComponent(variant)
        let tokenizerFolder = hub.localRepoLocation(.init(id: tokenizerRepo))
        if allowDownloads {
            try await Self.retryDownload {
                _ = try await WhisperKit.download(variant: variant, downloadBase: cacheRoot,
                    progressCallback: { progress($0.fractionCompleted * 0.9) })
                _ = try await hub.snapshot(from: .init(id: tokenizerRepo),
                    matching: ["tokenizer.json", "tokenizer_config.json", "config.json"])
            }
        }
        // Inject an explicitly local tokenizer. WhisperKit's default loader can
        // fall back to a network request even with download:false if its local
        // tokenizer is absent/corrupt; we must fail locally instead.
        guard FileManager.default.fileExists(atPath: modelFolder.path),
              FileManager.default.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path) else {
            throw CallScribeTranscriptionError.modelsNotPrepared
        }
        let tokenizer = try await LocalWhisperTokenizer.load(from: tokenizerFolder)
        let loaded = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path, verbose: false, prewarm: false, load: false, download: false))
        loaded.tokenizer = tokenizer
        loaded.textDecoder.isModelMultilingual = true
        try await loaded.loadModels()
        manager = loaded
        progress(1)
    }

    private static func retryDownload(_ operation: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            do { try await operation(); return }
            catch {
                let failure = error as NSError
                guard attempt < 2, failure.domain == NSURLErrorDomain,
                      [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(failure.code) else {
                    throw error
                }
                // The downloader preserves partial files and resumes via HTTP Range.
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
    }

    static func decodingOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language.rawValue,
            temperatureFallbackCount: 2, usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true,
            concurrentWorkerCount: 1)
    }

    static func captionOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        DecodingOptions(task: language == .english ? .transcribe : .translate,
            language: language.rawValue, temperatureFallbackCount: 0,
            usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
            withoutTimestamps: true, wordTimestamps: false, concurrentWorkerCount: 1)
    }

    public func englishCaption(samples: [Float], language: TranscriptionLanguage) async throws -> String {
        guard forLiveTranslation, let manager else { throw CallScribeTranscriptionError.modelsNotPrepared }
        guard !captionBusy else { throw CallScribeTranscriptionError.operationInProgress }
        captionBusy = true
        defer { captionBusy = false }
        try Task.checkCancellation()
        guard samples.count >= 4_800, samples.contains(where: { abs($0) > 0.0001 }) else { return "" }
        let results = try await manager.transcribe(audioArray: samples, decodeOptions: Self.captionOptions(for: language))
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        guard let manager else { throw CallScribeTranscriptionError.modelsNotPrepared }
        guard samples.count >= 4_800, samples.contains(where: { abs($0) > 0.0001 }) else { return .empty }
        let results = try await manager.transcribe(audioArray: samples, decodeOptions: Self.decodingOptions(for: language))
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
            RecognizedWord(text: $0.word.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: Double($0.start), endTime: Double($0.end), confidence: Double($0.probability))
        }
        return SpeechRecognitionResult(text: results.map(\.text).joined(separator: " "), words: words)
    }
}
