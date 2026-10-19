import CallScribeCore
import Foundation
import MicrosoftCognitiveServicesSpeech

/// Tracks exactly which PCM frames have been handed to the network worker.
/// The capture callback never performs network I/O.
public struct CaptionStreamCursor: Sendable {
    public private(set) var endFrame: Int64?
    public init() {}

    public mutating func consume(_ window: CaptionAudioWindow) -> (samples: [Float], gap: Bool) {
        let start = window.endFrame - Int64(window.samples.count)
        let gap = endFrame.map { $0 < start || $0 > window.endFrame } ?? false
        let from = gap ? start : max(start, endFrame ?? start)
        endFrame = window.endFrame
        return (Array(window.samples.dropFirst(Int(from - start))), gap)
    }
}

public struct AzureCaptionConfiguration: Sendable {
    public let key: String
    public let region: String
    public let maximumSeconds: Double
    public init(key: String, region: String, maximumSeconds: Double = 3_600) {
        self.key = key
        self.region = region
        self.maximumSeconds = maximumSeconds.isFinite ? min(28_800, max(1, maximumSeconds)) : 3_600
    }
}

/// One metered call-audio stream, English text output, no speech synthesis.
/// Azure's Recognizing events revise a draft before Recognized commits it.
public actor AzureLiveCaptionService {
    private var recognizer: SPXTranslationRecognizer?
    private var stream: SPXPushAudioInputStream?
    private var pump: Task<Void, Never>?
    private var generation: UUID?
    private var utteranceID = UUID().uuidString
    private var finalizedThrough: Double = -1
    private var audioOrigin: Double = 0
    private var callback: (@Sendable (LiveCaptionUpdate) -> Void)?
    private var lastText = ""
    private var totalSentFrames = 0
    private var cursor = CaptionStreamCursor()
    private var maximumFrames = 57_600_000
    private var stopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func resetSessionUsage() { totalSentFrames = 0 }

    public func start(configuration: AzureCaptionConfiguration, language: TranscriptionLanguage,
                      source: @escaping @Sendable () -> [CaptionAudioWindow],
                      update: @escaping @Sendable (LiveCaptionUpdate) -> Void) async throws {
        await stop()
        guard !Task.isCancelled else { return }
        guard Double(totalSentFrames) / 16_000 < configuration.maximumSeconds else {
            update(.init(status: "Azure caption time limit reached for this recording. Audio recording continues."))
            return
        }
        cursor = CaptionStreamCursor()
        maximumFrames = Int(configuration.maximumSeconds * 16_000)
        let token = UUID()
        generation = token
        callback = update
        lastText = ""
        utteranceID = UUID().uuidString
        finalizedThrough = -1
        update(.init(status: "Connecting to Azure · \(language.title) → English…", sessionID: token))
        let config = try SPXSpeechTranslationConfiguration(subscription: configuration.key, region: configuration.region)
        config.speechRecognitionLanguage = Self.locale(for: language)
        config.addTargetLanguage("en")
        config.setPropertyTo("500", byName: "Speech_SegmentationSilenceTimeoutMs")
        config.setPropertyTo("1", byName: "SpeechServiceResponse_StablePartialResultThreshold")
        let input = SPXPushAudioInputStream()
        guard let audio = SPXAudioConfiguration(streamInput: input) else {
            throw CallScribeTranscriptionError.modelsNotPrepared
        }
        let engine = try SPXTranslationRecognizer(speechTranslationConfiguration: config, audioConfiguration: audio)
        engine.addRecognizingEventHandler { [weak self] _, event in
            let text = (event.result.translations["en"] as? String) ?? (language == .english ? event.result.text ?? "" : "")
            let original = event.result.text ?? ""
            let offset = Double(event.result.offset) / 10_000_000
            let duration = Double(event.result.duration) / 10_000_000
            Task { await self?.receive(text: text, original: original, offset: offset, duration: duration, final: false, token: token) }
        }
        engine.addRecognizedEventHandler { [weak self] _, event in
            let text = (event.result.translations["en"] as? String) ?? (language == .english ? event.result.text ?? "" : "")
            let original = event.result.text ?? ""
            let offset = Double(event.result.offset) / 10_000_000
            let duration = Double(event.result.duration) / 10_000_000
            Task { await self?.receive(text: text, original: original, offset: offset, duration: duration, final: true, token: token) }
        }
        engine.addCanceledEventHandler { [weak self] _, event in
            let code = event.errorCode.rawValue
            Task { await self?.failed(token: token, code: code) }
        }
        stream = input
        recognizer = engine
        do { try engine.startContinuousRecognition() }
        catch {
            await stop()
            throw error
        }
        update(.init(status: "Azure · listening to call audio · English", sessionID: token))
        pump = Task { [weak self] in
            await self?.run(token: token, source: source, maximumSeconds: configuration.maximumSeconds)
        }
    }

    public static func locale(for language: TranscriptionLanguage) -> String {
        switch language {
        case .german: return "de-DE"
        case .turkish: return "tr-TR"
        case .english: return "en-US"
        }
    }

    private func receive(text: String, original: String, offset: Double, duration: Double, final: Bool, token: UUID) {
        guard generation == token, offset >= finalizedThrough - 0.02 else { return }
        if !text.isEmpty {
            lastText = text
            callback?(.init(callText: text, status: final ? "Azure · live English" : "Azure · live English · updating…",
                segment: .init(id: utteranceID, text: text, originalText: original,
                    startTime: audioOrigin + offset, isFinal: final), sessionID: token))
        }
        if final { finalizedThrough = offset + duration; utteranceID = UUID().uuidString }
    }

    private func run(token: UUID, source: @escaping @Sendable () -> [CaptionAudioWindow], maximumSeconds: Double) async {
        var idleSince: Date?
        var lastNotice = Date.distantPast
        while generation == token, !Task.isCancelled {
            if let window = source().first(where: { $0.track == .system }) {
                if window.endFrame != cursor.endFrame {
                    idleSince = nil
                    send(window, token: token)
                    if totalSentFrames >= maximumFrames {
                        await finishWithStatus("Azure caption time limit reached. Recording continues. Adjust the limit in Settings for your next session.")
                        return
                    }
                } else if idleSince == nil { idleSince = Date() }
            } else if idleSince == nil { idleSince = Date() }
            if let idleSince, Date().timeIntervalSince(idleSince) > 8, Date().timeIntervalSince(lastNotice) > 8 {
                callback?(.init(status: "No call audio arriving · check the meeting output device", sessionID: token))
                lastNotice = Date()
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
    }

    private func send(_ window: CaptionAudioWindow, token: UUID) {
        if cursor.endFrame == nil { audioOrigin = Double(window.endFrame - Int64(window.samples.count)) / 16_000 }
        let packet = cursor.consume(window)
        if packet.gap { callback?(.init(status: "Call audio reconnected · a caption gap may remain", sessionID: token)) }
        let samples = packet.samples.prefix(max(0, maximumFrames - totalSentFrames))
        guard !samples.isEmpty else { return }
        var pcm = samples.map { sample -> Int16 in
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            return Int16((clamped * 32_767).rounded()).littleEndian
        }
        stream?.write(pcm.withUnsafeMutableBytes { Data($0) })
        totalSentFrames += samples.count
    }

    public func finish(finalWindows: [CaptionAudioWindow]) async {
        if let token = generation, let window = finalWindows.first(where: { $0.track == .system }) { send(window, token: token) }
        await stop()
    }

    private func failed(token: UUID, code: UInt) async {
        guard generation == token, !stopping else { return }
        await finishWithStatus("Azure captions disconnected (code \(code)). Toggle captions to reconnect. Recording continues.")
    }

    private func finishWithStatus(_ status: String) async {
        let update = callback
        let token = generation
        await stop()
        update?(.init(callText: lastText, status: status, sessionID: token))
    }

    public func stop() async {
        if stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopping = true
        pump?.cancel()
        pump = nil
        let engine = recognizer
        stream?.close()
        if engine != nil {
            // EOF lets Azure finalize the tail before ending recognition. Keep
            // accepting events during this bounded drain; never block capture.
            try? await Task.sleep(nanoseconds: 800_000_000)
            try? engine?.stopContinuousRecognition()
            await Task.yield()
        }
        generation = nil
        recognizer = nil
        stream = nil
        callback = nil
        stopping = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
