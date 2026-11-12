import Foundation

/// A bounded-memory upload copy: microphone on channel 0, call audio on channel 1.
/// Original chunks are read-only; gaps remain silence at their recorded offsets.
public enum SavedAudioTimeline {
    public static func writeStereo(session: RecordingSession, to output: URL) throws -> Double {
        guard session.manifest.state != .recording, !session.manifest.chunks.isEmpty else {
            throw CallScribeCoreError.sessionCorrupt("Stop the recording before creating its transcript")
        }
        let chunks = session.manifest.chunks
        let limit: Int64 = 16_000 * 7_200
        for chunk in chunks {
            guard chunk.finalized, chunk.sampleRate == 16_000,
                  chunk.startFrame >= 0, chunk.frameCount >= 0,
                  chunk.startFrame <= limit, chunk.frameCount <= limit,
                  chunk.startFrame + chunk.frameCount <= limit else {
                throw CallScribeCoreError.sessionCorrupt("Saved transcription supports up to two hours of finalized audio")
            }
        }
        let frames = chunks.map { $0.startFrame + $0.frameCount }.max() ?? 0
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let destination = try FileHandle(forUpdating: output)
        defer { try? destination.close() }
        try destination.truncate(atOffset: UInt64(44 + frames * 4))
        try destination.seek(toOffset: 0)
        try destination.write(contentsOf: PCMEncoding.header(sampleRate: 16_000, channels: 2, frames: frames))
        let root = session.directoryURL.standardizedFileURL.path + "/"
        for chunk in chunks.sorted(by: { $0.startFrame < $1.startFrame }) {
            try Task.checkCancellation()
            let url = session.directoryURL.appendingPathComponent(chunk.relativePath).standardizedFileURL
            guard url.path.hasPrefix(root) else { throw CallScribeCoreError.sessionCorrupt("Invalid audio chunk path") }
            let info = try PCMEncoding.inspect(url)
            guard info.sampleRate == 16_000, info.channels == 1, info.frames == chunk.frameCount else {
                throw CallScribeCoreError.sessionCorrupt("Audio chunk does not match its manifest")
            }
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            try source.seek(toOffset: 44)
            var consumed: Int64 = 0
            let channel = chunk.track == .microphone ? 0 : 1
            while consumed < chunk.frameCount {
                try Task.checkCancellation()
                let count = Int(min(16_000, chunk.frameCount - consumed))
                let input = try source.read(upToCount: count * 2) ?? Data()
                guard input.count == count * 2 else { throw CallScribeCoreError.sessionCorrupt("Truncated audio chunk") }
                let offset = UInt64(44 + (chunk.startFrame + consumed) * 4)
                try destination.seek(toOffset: offset)
                var stereo = try destination.read(upToCount: count * 4) ?? Data()
                guard stereo.count == count * 4 else { throw CallScribeCoreError.sessionCorrupt("Incomplete upload copy") }
                input.withUnsafeBytes { samples in
                    stereo.withUnsafeMutableBytes { bytes in
                        let src = samples.bindMemory(to: UInt8.self)
                        let dst = bytes.bindMemory(to: UInt8.self)
                        for frame in 0..<count {
                            dst[frame * 4 + channel * 2] = src[frame * 2]
                            dst[frame * 4 + channel * 2 + 1] = src[frame * 2 + 1]
                        }
                    }
                }
                try destination.seek(toOffset: offset)
                try destination.write(contentsOf: stereo)
                consumed += Int64(count)
            }
        }
        try destination.synchronize()
        return Double(frames) / 16_000
    }
}
