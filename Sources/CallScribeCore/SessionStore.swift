import Foundation

/// Owns the durable session archive. Capture audio is appended to small, valid
/// WAV files; the JSON manifest is replaced atomically after every chunk and
/// at least every five seconds while a recording is active.
public final class SessionStore: @unchecked Sendable {
    public static let applicationFolderName = "CallScribe"
    public static let sessionsFolderName = "Sessions"

    public let rootURL: URL
    private let fileManager: FileManager

    public convenience init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(rootURL: support
            .appendingPathComponent(Self.applicationFolderName, isDirectory: true)
            .appendingPathComponent(Self.sessionsFolderName, isDirectory: true))
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func beginSession(
        microphoneUID: String? = nil,
        microphoneName: String? = nil,
        chunkDurationSeconds: TimeInterval = 15,
        language: TranscriptionLanguage = .english
    ) throws -> SessionRecorder {
        let id = UUID()
        let now = Date()
        let directory = rootURL.appendingPathComponent(Self.directoryName(date: now, id: id), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        for track in AudioTrack.allCases {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent(track.rawValue, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        var manifest = RecordingSessionManifest(
            id: id,
            createdAt: now,
            microphoneUID: microphoneUID,
            microphoneName: microphoneName,
            language: language
        )
        manifest.events.append(CaptureEvent(kind: .started, message: "Recording started"))
        try AtomicManifest.write(manifest, to: directory.appendingPathComponent("manifest.json"))
        return try SessionRecorder(
            directoryURL: directory,
            manifest: manifest,
            chunkFrameLimit: max(1, Int64((chunkDurationSeconds * 16_000).rounded()))
        )
    }

    public func sessions() throws -> [RecordingSession] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory -> RecordingSession? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return try? loadSession(at: directory)
        }
        .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func session(id: UUID) throws -> RecordingSession? {
        try sessions().first { $0.id == id }
    }

    public func loadSession(at directory: URL) throws -> RecordingSession {
        let manifest = try AtomicManifest.read(from: directory.appendingPathComponent("manifest.json"))
        return RecordingSession(directoryURL: directory, manifest: manifest)
    }

    /// Repairs any current partial WAV, preserves malformed data in Corrupt/, and
    /// marks sessions left in `recording` state as interrupted. Completed sessions
    /// are never rewritten.
    @discardableResult
    public func recoverInterruptedSessions() throws -> [RecordingSession] {
        var recovered: [RecordingSession] = []
        for session in try sessions() where session.manifest.state == .recording {
            var manifest = session.manifest
            var rebuilt: [AudioChunkMetadata] = []
            var recoveryMessages: [String] = []

            for track in AudioTrack.allCases {
                let trackURL = session.directoryURL.appendingPathComponent(track.rawValue, isDirectory: true)
                let files = (try? fileManager.contentsOfDirectory(
                    at: trackURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []

                for sourceURL in files
                    .filter({ $0.pathExtension == "wav" })
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    do {
                        let naming = try ChunkName.parse(sourceURL.lastPathComponent)
                        let info = try PCMEncoding.repairHeader(sourceURL)
                        var finalURL = sourceURL
                        if naming.partial {
                            finalURL = sourceURL
                                .deletingLastPathComponent()
                                .appendingPathComponent(ChunkName.finalName(index: naming.index, startFrame: naming.startFrame))
                            if fileManager.fileExists(atPath: finalURL.path) {
                                // A finalized sibling wins. Preserve this file for diagnosis.
                                try quarantine(sourceURL, sessionDirectory: session.directoryURL)
                                recoveryMessages.append("Preserved duplicate partial chunk \(sourceURL.lastPathComponent)")
                                continue
                            }
                            try fileManager.moveItem(at: sourceURL, to: finalURL)
                        }
                        rebuilt.append(AudioChunkMetadata(
                            track: track,
                            index: naming.index,
                            relativePath: "\(track.rawValue)/\(finalURL.lastPathComponent)",
                            startFrame: naming.startFrame,
                            frameCount: info.frames,
                            sampleRate: info.sampleRate,
                            finalized: true,
                            createdAt: (try? finalURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? manifest.createdAt
                        ))
                    } catch {
                        try? quarantine(sourceURL, sessionDirectory: session.directoryURL)
                        recoveryMessages.append("Preserved unreadable chunk \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }

            manifest.chunks = rebuilt.sorted(by: Self.chunkSort)
            manifest.state = .interrupted
            manifest.stoppedAt = Date()
            manifest.updatedAt = Date()
            manifest.events.append(CaptureEvent(
                kind: .recoveredAfterInterruption,
                message: "Recovered \(rebuilt.count) audio chunks after an interrupted recording"
            ))
            for message in recoveryMessages {
                manifest.events.append(CaptureEvent(kind: .warning, message: message))
            }
            try AtomicManifest.write(manifest, to: session.manifestURL)
            recovered.append(RecordingSession(directoryURL: session.directoryURL, manifest: manifest))
        }
        return recovered.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    private func quarantine(_ url: URL, sessionDirectory: URL) throws {
        let corrupt = sessionDirectory.appendingPathComponent("Corrupt", isDirectory: true)
        try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let destination = corrupt.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try fileManager.moveItem(at: url, to: destination)
    }

    private static func directoryName(date: Date, id: UUID) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)-\(id.uuidString.prefix(8))"
    }

    fileprivate static func chunkSort(_ lhs: AudioChunkMetadata, _ rhs: AudioChunkMetadata) -> Bool {
        if lhs.track != rhs.track { return lhs.track.rawValue < rhs.track.rawValue }
        if lhs.startFrame != rhs.startFrame { return lhs.startFrame < rhs.startFrame }
        return lhs.index < rhs.index
    }
}

public final class SessionRecorder: @unchecked Sendable {
    public let directoryURL: URL
    public let id: UUID
    public let sampleRate = 16_000

    private let manifestURL: URL
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let chunkFrameLimit: Int64
    private var manifest: RecordingSessionManifest
    private var writers: [AudioTrack: TrackChunkWriter] = [:]
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var storageError: String?

    public var lastStorageError: String? { onQueue { storageError } }

    fileprivate init(
        directoryURL: URL,
        manifest: RecordingSessionManifest,
        chunkFrameLimit: Int64
    ) throws {
        self.directoryURL = directoryURL
        self.id = manifest.id
        self.manifestURL = directoryURL.appendingPathComponent("manifest.json")
        self.manifest = manifest
        self.chunkFrameLimit = chunkFrameLimit
        self.queue = DispatchQueue(label: "app.callscribe.session.\(manifest.id.uuidString)", qos: .utility)
        self.queue.setSpecific(key: queueKey, value: ())
        for track in AudioTrack.allCases {
            writers[track] = TrackChunkWriter(
                track: track,
                directoryURL: directoryURL.appendingPathComponent(track.rawValue, isDirectory: true),
                sampleRate: sampleRate,
                frameLimit: chunkFrameLimit
            )
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            try? self?.flushOnQueue()
        }
        timer.resume()
        self.timer = timer
    }

    /// Enqueues samples without waiting for disk I/O. `startFrame` is relative to
    /// the shared monotonic session origin and keeps both tracks aligned. Gaps are
    /// represented as silence and recorded in the manifest; overlaps are trimmed.
    public func append(_ samples: [Float], to track: AudioTrack, startFrame: Int64) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.finished, let writer = self.writers[track] else { return }
            do {
                let outcome = try writer.append(samples, requestedStartFrame: max(0, startFrame))
                if outcome.gapFrames > 0 {
                    self.manifest.events.append(CaptureEvent(
                        kind: .gapInserted,
                        track: track,
                        frame: outcome.effectiveStartFrame - outcome.gapFrames,
                        frameCount: outcome.gapFrames,
                        message: "Inserted \(outcome.gapFrames) silent frames to preserve the capture timeline"
                    ))
                }
                if outcome.finalizedChunks > 0 {
                    try self.flushOnQueue()
                }
            } catch {
                self.storageError = error.localizedDescription
                self.manifest.events.append(CaptureEvent(
                    kind: .warning,
                    track: track,
                    message: "Audio write failed: \(error.localizedDescription)"
                ))
                try? self.flushOnQueue()
            }
        }
    }

    public func record(_ event: CaptureEvent) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.manifest.events.append(event)
            try? self.flushOnQueue()
        }
    }

    public func updateMicrophone(uid: String?, name: String?) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.manifest.microphoneUID = uid
            self.manifest.microphoneName = name
            try? self.flushOnQueue()
        }
    }

    public func flush() {
        queue.async { [weak self] in try? self?.flushOnQueue() }
    }

    public func flushSynchronously() throws {
        try onQueue { try flushOnQueue() }
    }

    public func snapshot() throws -> RecordingSession {
        try onQueue {
            try flushOnQueue()
            return RecordingSession(directoryURL: directoryURL, manifest: manifest)
        }
    }

    @discardableResult
    public func finish(state: RecordingSessionState = .complete, failureReason: String? = nil) throws -> RecordingSession {
        try onQueue {
            if finished {
                let diskManifest = try AtomicManifest.read(from: manifestURL)
                return RecordingSession(directoryURL: directoryURL, manifest: diskManifest)
            }
            timer?.cancel()
            timer = nil
            for writer in writers.values {
                try writer.finalizeCurrentChunk()
            }
            manifest.state = storageError == nil ? state : .failed
            manifest.failureReason = failureReason ?? storageError
            manifest.stoppedAt = Date()
            manifest.events.append(CaptureEvent(
                kind: .stopped,
                message: state == .complete ? "Recording stopped" : "Recording ended in state \(state.rawValue)"
            ))
            try flushOnQueue()
            finished = true
            return RecordingSession(directoryURL: directoryURL, manifest: manifest)
        }
    }

    private func flushOnQueue() throws {
        do {
        var chunks: [AudioChunkMetadata] = []
        for writer in writers.values {
            try writer.syncCurrentChunk()
            chunks.append(contentsOf: writer.metadata)
        }
        manifest.chunks = chunks.sorted(by: SessionStore.chunkSort)
        manifest.updatedAt = Date()
        try AtomicManifest.write(manifest, to: manifestURL)
        } catch {
            storageError = error.localizedDescription
            throw error
        }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    deinit {
        timer?.cancel()
    }
}

private final class TrackChunkWriter {
    struct AppendOutcome {
        let effectiveStartFrame: Int64
        let gapFrames: Int64
        let finalizedChunks: Int
    }

    let track: AudioTrack
    let directoryURL: URL
    let sampleRate: Int
    let frameLimit: Int64

    private(set) var metadata: [AudioChunkMetadata] = []
    private var currentHandle: FileHandle?
    private var currentURL: URL?
    private var currentIndex = 0
    private var currentStartFrame: Int64 = 0
    private var currentFrames: Int64 = 0
    private var nextFrame: Int64 = 0
    private var currentCreatedAt = Date()

    init(track: AudioTrack, directoryURL: URL, sampleRate: Int, frameLimit: Int64) {
        self.track = track
        self.directoryURL = directoryURL
        self.sampleRate = sampleRate
        self.frameLimit = frameLimit
    }

    func append(_ samples: [Float], requestedStartFrame: Int64) throws -> AppendOutcome {
        var offset = 0
        var start = requestedStartFrame
        if start < nextFrame {
            let overlap = min(Int64(samples.count), nextFrame - start)
            offset = Int(overlap)
            start += overlap
        }

        let gap = max(0, start - nextFrame)
        var finalized = 0
        if gap > 0 {
            finalized += try appendSilence(frameCount: gap)
        }
        if offset < samples.count {
            finalized += try appendContiguous(samples[offset...])
        }
        return AppendOutcome(effectiveStartFrame: start, gapFrames: gap, finalizedChunks: finalized)
    }

    func syncCurrentChunk() throws {
        guard let handle = currentHandle else { return }
        try patchHeader(handle: handle, frames: currentFrames)
        try handle.synchronize()
        updateCurrentMetadata(finalized: false)
        try handle.seekToEnd()
    }

    func finalizeCurrentChunk() throws {
        guard currentHandle != nil else { return }
        try finalize()
    }

    private func appendSilence(frameCount: Int64) throws -> Int {
        var remaining = frameCount
        var finalized = 0
        let zeroBatch = [Float](repeating: 0, count: 16_000)
        while remaining > 0 {
            let count = Int(min(remaining, Int64(zeroBatch.count)))
            finalized += try appendContiguous(zeroBatch[0..<count])
            remaining -= Int64(count)
        }
        return finalized
    }

    private func appendContiguous(_ samples: ArraySlice<Float>) throws -> Int {
        var cursor = samples.startIndex
        var finalized = 0
        while cursor < samples.endIndex {
            if currentHandle == nil { try openChunk() }
            let capacity = frameLimit - currentFrames
            let count = min(Int(capacity), samples.distance(from: cursor, to: samples.endIndex))
            let end = samples.index(cursor, offsetBy: count)
            try currentHandle?.write(contentsOf: PCMEncoding.int16Data(from: samples[cursor..<end]))
            currentFrames += Int64(count)
            nextFrame += Int64(count)
            cursor = end
            if currentFrames == frameLimit {
                try finalize()
                finalized += 1
            }
        }
        return finalized
    }

    private func openChunk() throws {
        currentStartFrame = nextFrame
        currentFrames = 0
        currentCreatedAt = Date()
        let name = ChunkName.partialName(index: currentIndex, startFrame: currentStartFrame)
        let url = directoryURL.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: PCMEncoding.header(sampleRate: sampleRate, channels: 1, frames: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        currentHandle = try FileHandle(forUpdating: url)
        try currentHandle?.seekToEnd()
        currentURL = url
    }

    private func finalize() throws {
        guard let handle = currentHandle, let partialURL = currentURL else { return }
        try patchHeader(handle: handle, frames: currentFrames)
        try handle.synchronize()
        try handle.close()
        let finalURL = partialURL
            .deletingLastPathComponent()
            .appendingPathComponent(ChunkName.finalName(index: currentIndex, startFrame: currentStartFrame))
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        currentURL = finalURL
        updateCurrentMetadata(finalized: true)
        currentHandle = nil
        currentURL = nil
        currentFrames = 0
        currentIndex += 1
    }

    private func patchHeader(handle: FileHandle, frames: Int64) throws {
        let offset = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: PCMEncoding.header(sampleRate: sampleRate, channels: 1, frames: frames))
        try handle.seek(toOffset: offset)
    }

    private func updateCurrentMetadata(finalized: Bool) {
        guard let url = currentURL else { return }
        let item = AudioChunkMetadata(
            track: track,
            index: currentIndex,
            relativePath: "\(track.rawValue)/\(url.lastPathComponent)",
            startFrame: currentStartFrame,
            frameCount: currentFrames,
            sampleRate: sampleRate,
            finalized: finalized,
            createdAt: currentCreatedAt
        )
        metadata.removeAll { $0.track == track && $0.index == currentIndex }
        metadata.append(item)
    }
}

enum ChunkName {
    struct Parsed {
        let index: Int
        let startFrame: Int64
        let partial: Bool
    }

    static func partialName(index: Int, startFrame: Int64) -> String {
        String(format: "%06d-%012lld.partial.wav", index, startFrame)
    }

    static func finalName(index: Int, startFrame: Int64) -> String {
        String(format: "%06d-%012lld.wav", index, startFrame)
    }

    static func parse(_ name: String) throws -> Parsed {
        let partial = name.hasSuffix(".partial.wav")
        let suffix = partial ? ".partial.wav" : ".wav"
        guard name.hasSuffix(suffix) else {
            throw CallScribeCoreError.sessionCorrupt("Unrecognized chunk name \(name)")
        }
        let stem = String(name.dropLast(suffix.count))
        let parts = stem.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let index = Int(parts[0]), let startFrame = Int64(parts[1]) else {
            throw CallScribeCoreError.sessionCorrupt("Unrecognized chunk name \(name)")
        }
        return Parsed(index: index, startFrame: startFrame, partial: partial)
    }
}

enum AtomicManifest {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func write(_ manifest: RecordingSessionManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    static func read(from url: URL) throws -> RecordingSessionManifest {
        try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: url))
    }
}
