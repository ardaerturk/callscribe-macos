import Foundation

enum PCMEncoding {
    static let headerSize: UInt64 = 44

    static func header(sampleRate: Int, channels: Int, frames: Int64) -> Data {
        let bytesPerSample = 2
        let dataBytes = max(0, frames) * Int64(channels * bytesPerSample)
        let clampedDataBytes = UInt32(clamping: dataBytes)
        let riffSize = UInt32(clamping: Int64(clampedDataBytes) + 36)
        let byteRate = UInt32(sampleRate * channels * bytesPerSample)
        let blockAlign = UInt16(channels * bytesPerSample)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // Linear PCM.
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(clampedDataBytes)
        return data
    }

    static func int16Data(from samples: ArraySlice<Float>) -> Data {
        var values = [Int16]()
        values.reserveCapacity(samples.count)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = min(1, max(-1, finite))
            let scaled = clamped >= 0 ? clamped * 32_767 : clamped * 32_768
            values.append(Int16(scaled.rounded()).littleEndian)
        }
        return values.withUnsafeBytes { Data($0) }
    }

    static func inspect(_ url: URL) throws -> WAVInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: Int(headerSize)) ?? Data()
        guard header.count == Int(headerSize),
              header.ascii(at: 0, count: 4) == "RIFF",
              header.ascii(at: 8, count: 4) == "WAVE",
              header.ascii(at: 12, count: 4) == "fmt ",
              header.ascii(at: 36, count: 4) == "data"
        else {
            throw CallScribeCoreError.sessionCorrupt("\(url.lastPathComponent) has no valid PCM WAV header")
        }

        let format: UInt16 = header.littleEndian(at: 20)
        let channels: UInt16 = header.littleEndian(at: 22)
        let sampleRate: UInt32 = header.littleEndian(at: 24)
        let bits: UInt16 = header.littleEndian(at: 34)
        guard format == 1, channels > 0, bits == 16 else {
            throw CallScribeCoreError.sessionCorrupt("\(url.lastPathComponent) is not 16-bit linear PCM")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= headerSize else {
            throw CallScribeCoreError.sessionCorrupt("\(url.lastPathComponent) is truncated")
        }
        let payloadBytes = fileSize - headerSize
        let bytesPerFrame = UInt64(channels) * 2
        let frames = Int64(payloadBytes / bytesPerFrame)
        return WAVInfo(sampleRate: Int(sampleRate), channels: Int(channels), frames: frames, payloadBytes: payloadBytes)
    }

    static func repairHeader(_ url: URL) throws -> WAVInfo {
        let existing = try inspect(url)
        guard existing.sampleRate == 16_000, existing.channels == 1 else {
            throw CallScribeCoreError.sessionCorrupt("Unexpected audio format in \(url.lastPathComponent)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= headerSize else {
            throw CallScribeCoreError.sessionCorrupt("\(url.lastPathComponent) is shorter than a WAV header")
        }
        // The recorder writes mono Int16. A single torn byte at the end is ignored.
        if (fileSize - headerSize) % 2 != 0 {
            fileSize -= 1
            let truncateHandle = try FileHandle(forWritingTo: url)
            try truncateHandle.truncate(atOffset: fileSize)
            try truncateHandle.close()
        }
        let frames = Int64((fileSize - headerSize) / 2)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleRate: 16_000, channels: 1, frames: frames))
        try handle.synchronize()
        try handle.close()
        return try inspect(url)
    }
}

struct WAVInfo: Equatable {
    let sampleRate: Int
    let channels: Int
    let frames: Int64
    let payloadBytes: UInt64
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= self.count else { return nil }
        return String(data: self[offset..<(offset + count)], encoding: .ascii)
    }

    func littleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        let byteCount = MemoryLayout<T>.size
        precondition(offset >= 0 && offset + byteCount <= count)
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset..<(offset + byteCount))
        }
        return T(littleEndian: value)
    }
}
