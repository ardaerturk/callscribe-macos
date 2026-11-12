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
        try check(settings.savedTranscriptProvider == .offline, "saved transcription needs its own explicit cloud choice")
        settings.captionFontSize = 32
        settings.captionProvider = .azure
        settings.savedTranscriptProvider = .azure
        let restored = AppSettings(defaults: defaults)
        try check(restored.captionFontSize == 32 && restored.captionProvider == .azure && restored.savedTranscriptProvider == .azure, "persist appearance and providers")
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
        guard let exported = try CaptionJournal.savedTranscript(in: directory) else {
            throw CallScribeBackendError.unavailable("Saved caption export was missing")
        }
        try check(exported.kind == .englishCaptions && exported.text.contains("We can meet Friday."), "recover English text after relaunch")

        // Exercise the same finalization path as Stop with a saved fixture.
        // This opens no microphone, network connection or model compiler.
        let store = try SessionStore(rootURL: directory.appendingPathComponent("Sessions"))
        let recorder = try store.beginSession(language: .german)
        recorder.append([0.1, 0.2, 0.1], to: .system, startFrame: 0)
        let stopped = try recorder.finish()
        let stoppedJournal = try CaptionJournal(directory: stopped.directoryURL)
        try stoppedJournal.receive(.init(segment: history.segments[0]))
        try stoppedJournal.close()
        let backend = CoreBackendAdapter()
        let started = Date()
        let stoppedResult = try await backend.finishSavedSession(stopped, formatting: .readable, progress: { _ in })
        try check(stoppedResult.kind == .englishCaptions, "Stop returns existing English without offline inference")
        try check(Date().timeIntervalSince(started) < 2, "caption finalization finishes promptly")
        let emptyRecorder = try store.beginSession(language: .german)
        emptyRecorder.append([0.1, 0.2], to: .system, startFrame: 0)
        let noCaptions = try emptyRecorder.finish()
        do {
            _ = try await backend.finishSavedSession(noCaptions, formatting: .readable, progress: { _ in })
            throw CallScribeBackendError.unavailable("Regression: missing captions unexpectedly produced text")
        } catch CallScribeBackendError.unavailable(let message) {
            try check(message.contains("No automatic model compilation"), "missing captions returns an actionable error without compiling")
        }

        let stereo = directory.appendingPathComponent("two-tracks.wav")
        _ = try SavedAudioTimeline.writeStereo(session: stopped, to: stereo)
        let stereoBytes = try Data(contentsOf: stereo)
        try check(stereoBytes.count == 44 + 3 * 4, "stereo upload preserves recorded frame count")
        try check(stereoBytes[22] == 2 && stereoBytes[44] == 0 && stereoBytes[45] == 0 && stereoBytes[46] != 0,
                  "call PCM goes to channel one; absent microphone remains silence")
        let pairedRecorder = try store.beginSession(language: .english)
        pairedRecorder.append([0.1, 0.2], to: .microphone, startFrame: 1)
        pairedRecorder.append([0.3, 0.4], to: .system, startFrame: 0)
        let paired = try pairedRecorder.finish()
        let pairedURL = directory.appendingPathComponent("paired.wav")
        _ = try SavedAudioTimeline.writeStereo(session: paired, to: pairedURL)
        let pairedBytes = try Data(contentsOf: pairedURL)
        try check(pairedBytes.count == 56 && String(data: pairedBytes.prefix(4), encoding: .ascii) == "RIFF",
                  "stereo upload has its header at the start and exactly three frames")
        try check(pairedBytes[44] == 0 && pairedBytes[46] != 0 && pairedBytes[48] != 0
                  && pairedBytes[50] != 0 && pairedBytes[52] != 0 && pairedBytes[54] == 0,
                  "both channels retain their own PCM and aligned silence gaps")
        let cached = Data("{\"phrases\":[{\"channel\":0,\"text\":\"My update.\",\"offsetMilliseconds\":0,\"durationMilliseconds\":500},{\"channel\":1,\"text\":\"Remote answer.\",\"offsetMilliseconds\":1000,\"durationMilliseconds\":500}]}".utf8)
        try cached.write(to: noCaptions.directoryURL.appendingPathComponent("azure-transcript-response.json"))
        await backend.configureLiveCaptions(enabled: false,
            settings: .init(provider: .azure, transcriptProvider: .azure), update: { _ in })
        let complete = try await backend.finishSavedSession(noCaptions, formatting: .timestamped, progress: { _ in })
        try check(complete.kind == .offlineTranscript && complete.text.contains("You: My update.") && complete.text.contains("Call: Remote answer."),
                  "saved transcription works with live captions off and includes both channels")
        let stateData = try Data(contentsOf: noCaptions.directoryURL.appendingPathComponent("processing-state.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let completedState = try decoder.decode(TranscriptProcessingState.self, from: stateData)
        try check(completedState.phase == .completed, "successful saved transcript has durable completion state")
        _ = try await backend.finishSavedSession(noCaptions, formatting: .plainText, progress: { _ in })
        try check(FileManager.default.fileExists(atPath: noCaptions.directoryURL.appendingPathComponent("transcript.md").path),
                  "cached retries export all files without credentials or another upload")
    }
}
