import CallScribeTranscription
import Foundation

/// Final captions are flushed during the meeting; the readable snapshot is
/// regenerated at Stop. Audio and the original-language transcript stay separate.
final class CaptionJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let file: FileHandle
    private var history = CaptionHistory()
    private var finalized = Set<String>()
    private var closed = false

    init(directory: URL) throws {
        self.directory = directory
        let url = directory.appendingPathComponent("english-captions.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
    }

    func receive(_ update: LiveCaptionUpdate) throws {
        guard let segment = update.segment else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        history.apply(segment)
        if segment.isFinal && finalized.insert(segment.id).inserted {
            var data = try JSONEncoder().encode(segment)
            data.append(0x0A)
            try file.write(contentsOf: data)
            try file.synchronize()
        }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        defer { try? file.close() }
        for segment in history.segments where !segment.isFinal {
            var data = try JSONEncoder().encode(segment)
            data.append(0x0A)
            try file.write(contentsOf: data)
        }
        try file.synchronize()
        let text = history.segments.map { segment in
            let seconds = Int(segment.startTime)
            let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            let draft = segment.isFinal ? "" : " (draft)"
            let original = segment.originalText.isEmpty ? "" : "\n\n> " + segment.originalText
            return "**\(timestamp)\(draft)** \(segment.text)\(original)"
        }.joined(separator: "\n\n")
        try Data(("# Live English captions\n\nMachine translations; drafts may be incomplete.\n\n" + text + "\n").utf8)
            .write(to: directory.appendingPathComponent("english-captions.md"), options: .atomic)
    }
}
