import FluidAudio
import Foundation

public typealias ModelPreparationProgress = @Sendable (Double) -> Void

public protocol OfflineSpeechRecognizing: Sendable {
    var isPrepared: Bool { get async }
    func prepareModels(progress: @escaping ModelPreparationProgress) async throws
    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult
}

public protocol OfflineSpeakerDiarizing: Sendable {
    var isPrepared: Bool { get async }
    func prepareModels(progress: @escaping ModelPreparationProgress) async throws
    func diarize(samples: [Float]) async throws -> [DiarizedSpeakerInterval]
    func diarize(file: URL) async throws -> [DiarizedSpeakerInterval]
}

public extension OfflineSpeakerDiarizing {
    func diarize(file: URL) async throws -> [DiarizedSpeakerInterval] {
        try await diarize(samples: FluidAudioSampleLoader().load16kMono(from: file))
    }
}

public protocol AudioSampleLoading: Sendable {
    func load16kMono(from url: URL) throws -> [Float]
}

public struct FluidAudioSampleLoader: AudioSampleLoading {
    public init() {}

    public func load16kMono(from url: URL) throws -> [Float] {
        try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
    }
}

/// English Parakeet Unified recognition with the compact INT8 encoder.
/// Models are loaded only from the
/// explicit `prepareModels` entry point; transcription never initiates a model
/// download implicitly.
public actor FluidAudioSpeechRecognizer: OfflineSpeechRecognizing {
    private var manager: UnifiedAsrManager?

    public init() {}

    public var isPrepared: Bool { manager != nil }

    public func prepareModels(progress: @escaping ModelPreparationProgress) async throws {
        progress(0)
        let loadedManager = UnifiedAsrManager(encoderPrecision: .int8)
        try await loadedManager.loadModels(
            progressHandler: { snapshot in
                progress(min(1, max(0, snapshot.fractionCompleted)))
            }
        )
        manager = loadedManager
        progress(1)
    }

    public func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        guard let manager else {
            throw CallScribeTranscriptionError.modelsNotPrepared
        }

        // Parakeet rejects buffers shorter than 300 ms. Such fragments cannot
        // produce useful word timings, so treat them as silence.
        guard samples.count >= 4_800 else { return .empty }

        // Avoid manufacturing words for exact digital silence (paused tracks).
        guard samples.contains(where: { abs($0) > 0.0001 }) else { return .empty }
        let result = try await manager.transcribeWithTimings(samples)
        let timings = buildWordTimings(from: result.tokenTimings)
        // This backend provides no calibrated word confidence.
        let confidence = 0.0
        let words = timings.map {
            RecognizedWord(
                text: $0.word,
                startTime: $0.startTime,
                endTime: $0.endTime,
                confidence: confidence
            )
        }
        return SpeechRecognitionResult(text: result.text, words: words, confidence: confidence)
    }
}

/// FluidAudio's offline Community-1 diarization pipeline. Loading is kept
/// separate from inference so a recording can never trigger an unexpected
/// network fetch.
public actor FluidAudioSpeakerDiarizer: OfflineSpeakerDiarizing {
    private final class ManagerBox: @unchecked Sendable {
        let value: OfflineDiarizerManager

        init(_ value: OfflineDiarizerManager) {
            self.value = value
        }
    }

    private let operationGate = AsyncOperationGate()
    private var manager: ManagerBox?

    public init() {}

    public var isPrepared: Bool { manager != nil }

    public func prepareModels(progress: @escaping ModelPreparationProgress) async throws {
        await operationGate.enter()
        progress(0)
        do {
            let models = try await OfflineDiarizerModels.load(
                progressHandler: { snapshot in
                    progress(min(1, max(0, snapshot.fractionCompleted)))
                }
            )
            let loadedManager = OfflineDiarizerManager(config: .default)
            loadedManager.initialize(models: models)
            manager = ManagerBox(loadedManager)
            progress(1)
            await operationGate.leave()
        } catch {
            await operationGate.leave()
            throw error
        }
    }

    public func diarize(samples: [Float]) async throws -> [DiarizedSpeakerInterval] {
        guard let manager else {
            throw CallScribeTranscriptionError.modelsNotPrepared
        }
        guard samples.count >= 4_800 else { return [] }

        await operationGate.enter()
        do {
            let result = try await manager.value.process(audio: samples)
            let intervals = result.segments.map {
                DiarizedSpeakerInterval(
                    speakerID: $0.speakerId,
                    startTime: Double($0.startTimeSeconds),
                    endTime: Double($0.endTimeSeconds)
                )
            }
            await operationGate.leave()
            return intervals
        } catch OfflineDiarizationError.noSpeechDetected {
            await operationGate.leave()
            return []
        } catch {
            await operationGate.leave()
            throw error
        }
    }

    public func diarize(file: URL) async throws -> [DiarizedSpeakerInterval] {
        guard let manager else { throw CallScribeTranscriptionError.modelsNotPrepared }
        await operationGate.enter()
        do {
            let result = try await manager.value.process(file)
            let intervals = result.segments.map {
                DiarizedSpeakerInterval(speakerID: $0.speakerId,
                    startTime: Double($0.startTimeSeconds), endTime: Double($0.endTimeSeconds))
            }
            await operationGate.leave()
            return intervals
        } catch OfflineDiarizationError.noSpeechDetected {
            await operationGate.leave()
            return []
        } catch {
            await operationGate.leave()
            throw error
        }
    }
}

private actor AsyncOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
