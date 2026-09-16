@testable import CallScribeCore
import Foundation
import XCTest

final class SessionStoreTests: XCTestCase {
    func testLanguageSurvivesInterruptedSessionRecovery() throws {
        let store = try makeStore()
        let recorder = try store.beginSession(language: .turkish)
        recorder.append([0.2, 0.3], to: .microphone, startFrame: 0)
        try recorder.flushSynchronously()
        let before = try recorder.snapshot()
        _ = try store.recoverInterruptedSessions()
        let after = try store.loadSession(at: before.directoryURL)
        XCTAssertEqual(after.manifest.language, .turkish)
    }

    func testLegacyManifestWithoutLanguageDefaultsToEnglish() throws {
        let encoded = try JSONEncoder().encode(RecordingSessionManifest())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "transcriptionLanguage")
        let manifest = try JSONDecoder().decode(RecordingSessionManifest.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(manifest.language, .english)
    }
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
    }

    func testSessionLayoutChunkingAndManifestAreDurable() throws {
        let store = try makeStore()
        let recorder = try store.beginSession(
            microphoneUID: "test-mic",
            microphoneName: "Test Microphone",
            chunkDurationSeconds: 0.001
        )
        recorder.append(Array(repeating: 0.25, count: 32), to: .microphone, startFrame: 0)
        recorder.append(Array(repeating: -0.25, count: 8), to: .system, startFrame: 0)

        let session = try recorder.finish()

        XCTAssertEqual(session.manifest.state, .complete)
        XCTAssertEqual(session.manifest.sampleRate, 16_000)
        XCTAssertEqual(session.manifest.microphoneUID, "test-mic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.directoryURL.appendingPathComponent("mic", isDirectory: true).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.directoryURL.appendingPathComponent("system", isDirectory: true).path
        ))

        let microphoneChunks = session.manifest.chunks.filter { $0.track == .microphone }
        XCTAssertEqual(microphoneChunks.map(\.frameCount), [16, 16])
        XCTAssertEqual(microphoneChunks.map(\.startFrame), [0, 16])
        XCTAssertTrue(microphoneChunks.allSatisfy(\.finalized))
        for url in session.audioURLs(for: .microphone) {
            let info = try PCMEncoding.inspect(url)
            XCTAssertEqual(info.sampleRate, 16_000)
            XCTAssertEqual(info.channels, 1)
            XCTAssertEqual(info.frames, 16)
        }

        let loaded = try store.loadSession(at: session.directoryURL)
        XCTAssertEqual(loaded.manifest.id, session.manifest.id)
        XCTAssertEqual(loaded.manifest.state, session.manifest.state)
        XCTAssertEqual(loaded.manifest.chunks.count, session.manifest.chunks.count)
        for (disk, memory) in zip(loaded.manifest.chunks, session.manifest.chunks) {
            XCTAssertEqual(disk.track, memory.track)
            XCTAssertEqual(disk.index, memory.index)
            XCTAssertEqual(disk.relativePath, memory.relativePath)
            XCTAssertEqual(disk.startFrame, memory.startFrame)
            XCTAssertEqual(disk.frameCount, memory.frameCount)
            XCTAssertEqual(disk.sampleRate, memory.sampleRate)
            XCTAssertEqual(disk.finalized, memory.finalized)
        }
        XCTAssertEqual(loaded.manifest.events.map(\.id), session.manifest.events.map(\.id))
        XCTAssertEqual(loaded.manifest.events.map(\.kind), session.manifest.events.map(\.kind))
    }

    func testGapInsertionKeepsAbsoluteTrackPosition() throws {
        let store = try makeStore()
        let recorder = try store.beginSession(chunkDurationSeconds: 1)
        recorder.append([0.2, 0.3, 0.4], to: .system, startFrame: 10)

        let session = try recorder.finish()
        let chunk = try XCTUnwrap(session.manifest.chunks.first { $0.track == .system })

        XCTAssertEqual(chunk.startFrame, 0)
        XCTAssertEqual(chunk.frameCount, 13)
        XCTAssertTrue(session.manifest.events.contains {
            $0.kind == .gapInserted && $0.track == .system && $0.frameCount == 10
        })
        XCTAssertEqual(try PCMEncoding.inspect(session.audioURLs(for: .system)[0]).frames, 13)
    }

    func testInterruptedPartialWAVIsFinalizedAndManifestRebuilt() throws {
        let store = try makeStore()
        var recorder: SessionRecorder? = try store.beginSession(chunkDurationSeconds: 60)
        let directory = try XCTUnwrap(recorder).directoryURL
        recorder?.append(Array(repeating: 0.1, count: 100), to: .microphone, startFrame: 0)
        try recorder?.flushSynchronously()
        recorder = nil

        let beforeRecovery = try store.sessions()
        XCTAssertEqual(beforeRecovery.count, 1, "expected the recording manifest to remain discoverable")
        XCTAssertEqual(beforeRecovery.first?.manifest.state, .recording)
        let recovered = try store.recoverInterruptedSessions()
        let originalID = try XCTUnwrap(beforeRecovery.first?.id)
        let session = try XCTUnwrap(recovered.first { $0.id == originalID })

        XCTAssertEqual(session.directoryURL.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(session.manifest.state, .interrupted)
        XCTAssertEqual(session.manifest.chunks.count, 1)
        XCTAssertTrue(session.manifest.chunks[0].finalized)
        XCTAssertFalse(session.manifest.chunks[0].relativePath.contains("partial"))
        XCTAssertEqual(try PCMEncoding.inspect(session.audioURLs(for: .microphone)[0]).frames, 100)
        XCTAssertTrue(session.manifest.events.contains { $0.kind == .recoveredAfterInterruption })
    }

    private func makeStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallScribeCoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(root)
        return try SessionStore(rootURL: root)
    }

    func testDiskWriteFailureIsExposedAndNeverMarkedComplete() throws {
        let store = try makeStore()
        let recorder = try store.beginSession()
        let mic = recorder.directoryURL.appendingPathComponent("mic")
        try FileManager.default.removeItem(at: mic)
        try Data("not a directory".utf8).write(to: mic)
        recorder.append([0.25], to: .microphone, startFrame: 0)
        let session = try recorder.finish()
        XCTAssertNotNil(recorder.lastStorageError)
        XCTAssertEqual(session.manifest.state, .failed)
        XCTAssertNotNil(session.manifest.failureReason)
    }

    func testCorruptChunkIsPreservedAndOtherAudioRecovers() throws {
        let store = try makeStore()
        var recorder: SessionRecorder? = try store.beginSession(chunkDurationSeconds: 0.001)
        let directory = try XCTUnwrap(recorder).directoryURL
        recorder?.append([Float](repeating: 0.2, count: 32), to: .microphone, startFrame: 0)
        try recorder?.flushSynchronously()
        recorder = nil
        let damaged = directory.appendingPathComponent("mic/000000-000000000000.wav")
        try Data(repeating: 0xff, count: 100).write(to: damaged)
        let recovered = try XCTUnwrap(store.recoverInterruptedSessions().first)
        XCTAssertEqual(recovered.manifest.chunks.count, 1)
        XCTAssertEqual(recovered.manifest.chunks[0].startFrame, 16)
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Corrupt").path)
        XCTAssertEqual(preserved.count, 1)
    }
}
