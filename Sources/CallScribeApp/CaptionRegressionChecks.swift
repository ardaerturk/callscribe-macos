import CallScribeCore
import CallScribeTranscription
import Foundation
import AppKit
import SwiftUI

/// A portable diagnostics runner for Macs with Command Line Tools but no XCTest.
/// The XCTest suite contains the same regression cases for full Xcode hosts.
enum CaptionRegressionChecks {
    @MainActor static func run() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            if !condition() { throw CallScribeBackendError.unavailable("Regression: " + name) }
        }
        var history = CaptionHistory()
        history.apply(.init(id: "a", text: "We can", startTime: 0, isFinal: false))
        history.apply(.init(id: "a", text: "We can meet Friday.", startTime: 0, isFinal: true))
        history.apply(.init(id: "a", text: "We", startTime: 0, isFinal: false))
        history.apply(.init(id: "b", text: "We can meet Friday.", startTime: 8, isFinal: true))
        try check(history.segments.count == 2, "one row per utterance; preserve repeated sentences")
        try check(history.segments[0].text == "We can meet Friday.", "late partial cannot overwrite final")
        var cursor = CaptionStreamCursor()
        try check(cursor.consume(.init(track: .system, samples: [1, 2, 3], endFrame: 3)).samples == [1, 2, 3], "initial PCM")
        try check(cursor.consume(.init(track: .system, samples: [2, 3, 4, 5], endFrame: 5)).samples == [4, 5], "send overlap only once")
        try check(cursor.consume(.init(track: .system, samples: [2, 3, 4, 5], endFrame: 5)).samples.isEmpty, "stalled source cannot be resent")
        try check(cursor.consume(.init(track: .system, samples: [6, 7], endFrame: 100)).gap, "report overwritten PCM")
        try check(cursor.consume(.init(track: .system, samples: [8, 9], endFrame: 2)).gap, "clock reset")
        var following = true
        let binding = Binding(get: { following }, set: { following = $0 })
        let entries = (0..<30).map { CaptionSegment(id: "scroll-\($0)", text: "Earlier sentence number \($0) remains available while the meeting continues.", startTime: Double($0), isFinal: true) }
        let host = NSHostingView(rootView: CaptionTranscriptView(segments: entries, fontSize: 23, showOriginal: false, followingLive: binding))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 130)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        guard let scroll = scrollView(in: host), let textView = scroll.documentView as? NSTextView else {
            throw CallScribeBackendError.unavailable("Caption scroll view was not created")
        }
        // Simulate content scrolling inside our own view, without desktop input.
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try check(!following, "scrolling up pauses follow mode")
        let frozenText = textView.string
        let more = entries + [.init(id: "new", text: "New speech while reading", startTime: 31, isFinal: true)]
        host.rootView = CaptionTranscriptView(segments: more, fontSize: 23, showOriginal: false, followingLive: binding)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        try check(textView.string == frozenText, "incoming words do not move a reader's frozen snapshot")
        following = true
        host.rootView = CaptionTranscriptView(segments: more, fontSize: 23, showOriginal: false, followingLive: binding)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        try check(textView.string.contains("New speech while reading"), "return to live reveals queued captions")
        let suite = "CallScribe.Check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        try check(settings.captionProvider == .offline, "never opt users into cloud automatically")
        settings.captionFontSize = 32
        settings.captionProvider = .azure
        let restored = AppSettings(defaults: defaults)
        try check(restored.captionFontSize == 32 && restored.captionProvider == .azure, "persist appearance and provider")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CallScribe-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try CaptionJournal(directory: directory)
        for segment in history.segments { try journal.receive(.init(segment: segment)) }
        try journal.receive(.init(segment: history.segments[0]))
        try journal.close()
        let lines = try String(contentsOf: directory.appendingPathComponent("english-captions.jsonl"), encoding: .utf8).split(separator: "\n")
        try check(lines.count == 2, "archive finals once")
        try check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("english-captions.md").path), "readable archive at stop")
    }
}
