import CallScribeCore
import CallScribeTranscription
import Foundation

/// Optional terminal checks. These never open microphone or meeting inputs.
enum AppDiagnostics {
    @MainActor
    static func startIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--prepare-models") || arguments.contains("--verify-models")
            || arguments.contains("--prepare-captions") || arguments.contains("--verify-captions")
            || arguments.contains("--verify-live-captions") || arguments.contains("--preview-captions") else { return false }
        Task {
            do {
                if arguments.contains("--preview-captions") {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("CallScribe/Verification")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("caption-preview.png")
                    try CaptionOverlay.renderPreview(to: url)
                    print(url.path)
                    exit(0)
                }
                let code = arguments.firstIndex(of: "--language").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                } ?? "en"
                guard let language = TranscriptionLanguage(rawValue: code) else {
                    throw CallScribeBackendError.unavailable("Choose --language en, tr, or de")
                }
                if arguments.contains("--prepare-captions") || arguments.contains("--verify-captions") || arguments.contains("--verify-live-captions") {
                    let translator = WhisperSpeechRecognizer(language: language, forLiveTranslation: true)
                    let download = arguments.contains("--prepare-captions")
                    print(download ? "Preparing local caption model…" : "Checking local English translation (downloads disabled)…")
                    fflush(stdout)
                    try await translator.prepareModels(allowDownloads: download, progress: { _ in })
                    if !download {
                        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        let directory = support.appendingPathComponent("CallScribe/Verification/\(language.rawValue)")
                        if arguments.contains("--verify-live-captions") {
                            let micFixture = try FluidAudioSampleLoader().load16kMono(from: directory.appendingPathComponent("mic.aiff"))
                            let callFixture = try FluidAudioSampleLoader().load16kMono(from: directory.appendingPathComponent("system.aiff"))
                            // Repeat the short fixtures with a pause so the check
                            // exercises updates after the six-second warm-up.
                            let mic = micFixture + [Float](repeating: 0, count: 16_000) + micFixture
                            let call = callFixture + [Float](repeating: 0, count: 16_000) + callFixture
                            let checkDuration = Double(max(mic.count, call.count)) / 16_000 + 4
                            let clock = Date()
                            let service = LiveCaptionService(translator: translator)
                            let (updates, continuation) = AsyncStream<LiveCaptionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
                            await service.start(language: language, source: {
                                let frame = Int(Date().timeIntervalSince(clock) * 16_000)
                                return [(AudioTrack.microphone, mic), (AudioTrack.system, call)].map { track, samples in
                                    let end = min(frame, samples.count)
                                    return CaptionAudioWindow(track: track, samples: Array(samples.prefix(end).suffix(128_000)), endFrame: Int64(end))
                                }
                            }, update: { continuation.yield($0) })
                            var translatedUpdates = 0
                            for await update in updates {
                                let elapsed = Date().timeIntervalSince(clock)
                                print(String(format: "%.1fs", elapsed), "Call:", update.callText, "You:", update.yourText)
                                fflush(stdout)
                                if !update.callText.isEmpty || !update.yourText.isEmpty { translatedUpdates += 1 }
                                if elapsed >= checkDuration { break }
                            }
                            await service.stop()
                            continuation.finish()
                            guard translatedUpdates >= 2 else {
                                throw CallScribeBackendError.unavailable("Rolling caption check produced fewer than two nonempty updates; no recording was created.")
                            }
                            print("PASS: rolling caption updates from synthetic audio; no live inputs opened")
                            exit(0)
                        }
                        for name in ["mic", "system"] {
                            let samples = try FluidAudioSampleLoader().load16kMono(from: directory.appendingPathComponent("\(name).aiff"))
                            let result = try await translator.englishCaption(samples: samples, language: language)
                            print("\(name): \(result)")
                            guard !result.isEmpty else { throw CallScribeBackendError.noTranscript }
                        }
                    }
                    print("PASS")
                    exit(0)
                }
                let processor = MeetingNotesProcessor(language: language)
                let download = arguments.contains("--prepare-models")
                print(download ? "Preparing local models…" : "Loading local models with downloads disabled…")
                try await processor.prepareModels(allowDownloads: download)
                if !download {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let directory = support.appendingPathComponent("CallScribe/Verification/\(language.rawValue)", isDirectory: true)
                    let store = try SessionStore(rootURL: directory.appendingPathComponent("Sessions"))
                    let recorder = try store.beginSession(language: language)
                    let loader = FluidAudioSampleLoader()
                    for track in AudioTrack.allCases {
                        var samples = try loader.load16kMono(from: directory.appendingPathComponent("\(track.rawValue).aiff"))
                        let secondSpeaker = directory.appendingPathComponent("system2.aiff")
                        if track == .system, FileManager.default.fileExists(atPath: secondSpeaker.path) {
                            samples += [Float](repeating: 0, count: 16_000)
                            samples += try loader.load16kMono(from: secondSpeaker)
                        }
                        recorder.append(samples, to: track, startFrame: 0)
                    }
                    let session = try recorder.finish()
                    let result = try await processor.process(session: session)
                    print(result.transcript.rendered(as: .timestamped))
                    print("Saved verification: \(result.textURL.path)")
                    guard result.transcript.segments.contains(where: { $0.speaker == "You" }),
                          result.transcript.segments.contains(where: { $0.source == .meetingAudio }) else {
                        throw CallScribeBackendError.unavailable("Verification did not produce both sides.")
                    }
                    let remoteSpeakers = Set(result.transcript.segments.filter { $0.source == .meetingAudio }.map(\.speaker))
                    print("Remote speaker labels: \(remoteSpeakers.sorted().joined(separator: ", "))")
                    let expected: [String]
                    switch language {
                    case .english: expected = ["project", "budget", "delivery", "design"]
                    case .turkish: expected = ["proje", "bütçe", "tasarım", "gelecek"]
                    case .german: expected = ["projektplan", "bericht", "entwürfe", "ergebnisse"]
                    }
                    let text = result.transcript.segments.map(\.text).joined(separator: " ").lowercased()
                    guard expected.allSatisfy({ text.contains($0) }) else {
                        throw CallScribeBackendError.unavailable("Verification missed expected words in \(language.title). Inspect the saved transcript.")
                    }
                }
                print("PASS")
                exit(0)
            } catch {
                fputs("Check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        return true
    }
}
