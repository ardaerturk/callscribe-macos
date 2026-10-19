import CallScribeCore
import Foundation

public struct LiveCaptionUpdate: Equatable, Sendable {
    public var callText: String
    public var yourText: String
    public var status: String
    public var segment: CaptionSegment?
    public var sessionID: UUID?

    public init(callText: String = "", yourText: String = "", status: String = "Listening…",
                segment: CaptionSegment? = nil, sessionID: UUID? = nil) {
        self.callText = callText
        self.yourText = yourText
        self.status = status
        self.segment = segment
        self.sessionID = sessionID
    }
}

public protocol EnglishCaptionTranslating: Sendable {
    func prepareModels(allowDownloads: Bool, progress: @escaping ModelPreparationProgress) async throws
    func englishCaption(samples: [Float], language: TranscriptionLanguage) async throws -> String
    func englishCaption(samples: [Float], language: TranscriptionLanguage,
                        partial: @escaping @Sendable (String) -> Void) async throws -> String
}

public extension EnglishCaptionTranslating {
    func englishCaption(samples: [Float], language: TranscriptionLanguage,
                        partial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await englishCaption(samples: samples, language: language)
    }
}

extension WhisperSpeechRecognizer: EnglishCaptionTranslating {}

/// Revises growing chronological windows on a single worker. Slow inference
/// consumes retained audio in order and reports any buffer overrun explicitly.
public actor LiveCaptionService {
    private let translator: any EnglishCaptionTranslating
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private let intervalNanoseconds: UInt64

    public init(translator: any EnglishCaptionTranslating = WhisperSpeechRecognizer(language: .english, forLiveTranslation: true),
                intervalNanoseconds: UInt64 = 500_000_000) {
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
        update(.init(status: "Loading offline English captions…", sessionID: token))
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
        var cursors: [AudioTrack: Int64] = [:]
        var attemptedEnds: [AudioTrack: Int64] = [:]
        var latest: [AudioTrack: String] = [:]
        while generation == token, !Task.isCancelled {
            let cycleStart = Date()
            for window in source().sorted(by: { $0.track == .system && $1.track != .system }) {
                guard generation == token, !Task.isCancelled else { return }
                let availableStart = window.endFrame - Int64(window.samples.count)
                var start = cursors[window.track] ?? availableStart
                if start < availableStart || start > window.endFrame {
                    start = availableStart
                    update(.init(status: "Audio gap: offline captions could not keep up. Saved recording is available.", sessionID: token))
                }
                cursors[window.track] = start
                let end = min(window.endFrame, start + 128_000)
                guard end - start >= 24_000, attemptedEnds[window.track] != end else { continue }
                let samples = Array(window.samples[Int(start - availableStart)..<Int(end - availableStart)])
                guard Self.hasRecentSpeechEnergy(samples) else {
                    cursors[window.track] = end
                    continue
                }
                let final = end - start >= 128_000 || !Self.hasRecentSpeechEnergy(Array(samples.suffix(11_200)))
                let id = "\(token)-\(window.track.rawValue)-\(start)"
                let segmentStart = Double(start) / 16_000
                do {
                    let text = try await translator.englishCaption(samples: samples, language: language) { text in
                        // The consumer also checks the session generation. Decoder
                        // callbacks are provisional, never appended as new sentences.
                        update(.init(status: "Offline · translating…", segment: .init(id: id, text: text,
                            startTime: segmentStart, isFinal: false, track: window.track), sessionID: token))
                    }
                    guard generation == token, !Task.isCancelled else { return }
                    attemptedEnds[window.track] = end
                    if final { cursors[window.track] = end }
                    if !text.isEmpty { latest[window.track] = text }
                    let lag = max(0, Double((source().first { $0.track == window.track }?.endFrame ?? end) - end) / 16_000)
                    update(.init(callText: latest[.system] ?? "", yourText: latest[.microphone] ?? "",
                        status: lag > 3 ? String(format: "Offline · %.0fs behind · catching up", lag) : "Offline · English · draft may change",
                        segment: .init(id: id, text: text, startTime: segmentStart, isFinal: final, track: window.track), sessionID: token))
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    update(.init(status: "Offline captions failed; retrying. Recording continues.", sessionID: token))
                }
            }
            let elapsed = Date().timeIntervalSince(cycleStart)
            let delay = max(0.05, Double(intervalNanoseconds) / 1_000_000_000 - elapsed)
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
        }
    }

    static func hasRecentSpeechEnergy(_ samples: [Float]) -> Bool {
        guard samples.count >= 4_800 else { return false }
        // Inspect the whole unprocessed span, not just its last two seconds:
        // a pause after speech must not throw away the preceding speech.
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let block = samples[start..<min(samples.count, start + 1_600)]
            let energy = block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block.count)
            if energy > 0.00000064 { return true }
        }
        return false
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
