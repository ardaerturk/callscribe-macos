import CallScribeCore
import Foundation

public struct LiveCaptionUpdate: Equatable, Sendable {
    public var callText: String
    public var yourText: String
    public var status: String

    public init(callText: String = "", yourText: String = "", status: String = "Listening…") {
        self.callText = callText
        self.yourText = yourText
        self.status = status
    }
}

public protocol EnglishCaptionTranslating: Sendable {
    func prepareModels(allowDownloads: Bool, progress: @escaping ModelPreparationProgress) async throws
    func englishCaption(samples: [Float], language: TranscriptionLanguage) async throws -> String
}

extension WhisperSpeechRecognizer: EnglishCaptionTranslating {}

/// At most one rolling window per track is processed at a time. There is no
/// work queue of old speech: a slow machine takes the newest snapshot next.
public actor LiveCaptionService {
    private let translator: any EnglishCaptionTranslating
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private let intervalNanoseconds: UInt64

    public init(translator: any EnglishCaptionTranslating = WhisperSpeechRecognizer(language: .english, forLiveTranslation: true),
                intervalNanoseconds: UInt64 = 3_000_000_000) {
        self.translator = translator
        self.intervalNanoseconds = intervalNanoseconds
    }

    public func prepareModels(progress: @escaping ModelPreparationProgress) async throws {
        guard generation == nil else { throw CallScribeTranscriptionError.operationInProgress }
        try await translator.prepareModels(allowDownloads: true, progress: progress)
    }

    public func start(language: TranscriptionLanguage,
                      source: @escaping @Sendable () -> [CaptionAudioWindow],
                      update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async {
        guard !Task.isCancelled else { return }
        stop()
        let token = UUID()
        generation = token
        update(.init(status: "Loading offline English captions…"))
        do {
            try await translator.prepareModels(allowDownloads: false, progress: { _ in })
            guard generation == token, !Task.isCancelled else { return }
            task = Task { [weak self] in
                await self?.run(token: token, language: language, source: source, update: update)
            }
        } catch {
            guard generation == token else { return }
            generation = nil
            update(.init(status: "Captions unavailable: \(error.localizedDescription) Recording is unaffected."))
        }
    }

    public func stop() {
        generation = nil
        task?.cancel()
        task = nil
    }

    private func run(token: UUID, language: TranscriptionLanguage,
                     source: @escaping @Sendable () -> [CaptionAudioWindow],
                     update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async {
        var lastFrames: [AudioTrack: Int64] = [:]
        var texts: [AudioTrack: String] = [:]
        while generation == token, !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: intervalNanoseconds) } catch { return }
            guard generation == token, !Task.isCancelled else { return }
            let started = Date()
            let windows = source().sorted { $0.track == .system && $1.track != .system }
            let present = Set(windows.map(\.track))
            for track in AudioTrack.allCases where !present.contains(track) { texts[track] = nil }
            do {
                for window in windows {
                    guard generation == token, !Task.isCancelled else { return }
                    guard lastFrames[window.track] != window.endFrame else {
                        texts[window.track] = nil
                        continue
                    }
                    lastFrames[window.track] = window.endFrame
                    guard Self.hasRecentSpeechEnergy(window.samples) else {
                        texts[window.track] = nil
                        continue
                    }
                    let text = try await translator.englishCaption(samples: window.samples, language: language)
                    guard generation == token, !Task.isCancelled else { return }
                    texts[window.track] = String(text.suffix(420))
                }
                guard generation == token, !Task.isCancelled else { return }
                let call = texts[.system] ?? ""
                var you = texts[.microphone] ?? ""
                if Self.isLikelyEcho(you, of: call) { you = "" }
                // Discard excessively late translations rather than displaying
                // them as current. Recording is never stopped by caption lag.
                if Date().timeIntervalSince(started) > 12 {
                    update(.init(status: "Captions are falling behind; catching up to current audio…"))
                } else {
                    update(.init(callText: call, yourText: you,
                        status: call.isEmpty && you.isEmpty ? "Listening for speech…" : "English · live translation · may contain errors"))
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                update(.init(status: "Caption processing failed; retrying. Recording continues."))
            }
        }
    }

    static func hasRecentSpeechEnergy(_ samples: [Float]) -> Bool {
        // Very short opening fragments produced an unrelated translation in
        // the German smoke test. Wait for context after start/route resets.
        // This reduces that risk; it is not a translation-accuracy guarantee.
        guard samples.count >= 96_000 else { return false }
        let recent = samples.suffix(32_000)
        let meanSquare = recent.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(recent.count)
        return meanSquare > 0.000016
    }

    static func isLikelyEcho(_ microphone: String, of call: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let mic = words(microphone), remote = words(call)
        guard mic.count >= 3, remote.count >= 3 else { return false }
        return Double(mic.intersection(remote).count) / Double(max(mic.count, remote.count)) > 0.8
    }
}
