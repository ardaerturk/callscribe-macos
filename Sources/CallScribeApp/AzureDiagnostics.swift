import AppKit
import CallScribeCore
import CallScribeTranscription
import Foundation

enum AzureDiagnostics {
    @MainActor private static var demo: CaptionOverlay?

    @MainActor static func startIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--demo-captions") {
            let overlay = CaptionOverlay(settings: AppSettings())
            demo = overlay
            overlay.beginSession()
            Task {
                for index in 0..<40 {
                    overlay.show(.init(status: "Preview · sample captions · no audio recorded",
                        segment: .init(id: "demo-\(index)", text: Self.examples[index % Self.examples.count],
                            originalText: "Beispieltext für die Besprechung.", startTime: Double(index * 5), isFinal: true)))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            return true
        }
        guard args.contains("--configure-azure") || args.contains("--verify-azure") || args.contains("--verify-configured-azure") || args.contains("--verify-caption-logic") || args.contains("--verify-microphone") || args.contains("--recover-session") else { return false }
        Task {
            do {
                if args.contains("--verify-microphone") {
                    let result = try await MicrophoneCaptureProbe.run(deviceUID: AppSettings().selectedMicrophoneID)
                    print("PASS: " + result + ". Microphone audio was not saved or transmitted.")
                    exit(0)
                }
                if let index = args.firstIndex(of: "--recover-session"), args.indices.contains(index + 1) {
                    let directory = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
                    let store = try SessionStore(rootURL: directory.deletingLastPathComponent())
                    guard let session = try store.sessions().first(where: { $0.directoryURL.standardizedFileURL == directory }) else {
                        throw CallScribeBackendError.unavailable("Saved session not found.")
                    }
                    let processor = MeetingNotesProcessor(language: session.manifest.language)
                    try await processor.prepareModels(allowDownloads: false)
                    let artifacts = try await processor.process(session: session) { value in
                        print("Recovery progress: \(Int(value * 100))%")
                        fflush(stdout)
                    }
                    print("Recovered transcript: \(artifacts.textURL.path)")
                    exit(0)
                }
                if args.contains("--verify-caption-logic") {
                    try await CaptionRegressionChecks.run()
                    print("PASS: caption history, PCM continuity, settings and archive regression checks")
                    exit(0)
                }
                // Provisioning input is read from stdin; credentials never appear
                // in process arguments, logs, or the repository.
                let input: Configuration
                if args.contains("--verify-configured-azure") {
                    guard let key = try AzureCredentialStore.read() else {
                        throw CallScribeBackendError.unavailable("Azure key is missing from Keychain.")
                    }
                    let settings = AppSettings()
                    guard settings.captionProvider == .azure else {
                        throw CallScribeBackendError.unavailable("Azure is not the selected caption provider.")
                    }
                    input = Configuration(key: key, region: settings.azureRegion)
                } else {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    input = try JSONDecoder().decode(Configuration.self, from: data)
                }
                if args.contains("--configure-azure") {
                    try AzureCredentialStore.save(input.key)
                    let settings = AppSettings()
                    settings.azureRegion = input.region
                    settings.captionProvider = .azure
                    settings.liveCaptionsEnabled = true
                    print("Azure configured; key saved in Keychain.")
                    exit(0)
                }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let externalFixture = args.firstIndex(of: "--audio-file").flatMap { index in
                    args.indices.contains(index + 1) ? URL(fileURLWithPath: args[index + 1]) : nil
                }
                let url = externalFixture ?? support.appendingPathComponent("CallScribe/Verification/de/system.aiff")
                let samples = try FluidAudioSampleLoader().load16kMono(from: url)
                let began = Date()
                let service = AzureLiveCaptionService()
                let (events, continuation) = AsyncStream<LiveCaptionUpdate>.makeStream()
                try await service.start(configuration: .init(key: input.key, region: input.region, maximumSeconds: 40), language: .german, source: {
                    let end = min(samples.count + 48_000, Int(Date().timeIntervalSince(began) * 16_000))
                    let padded = samples + [Float](repeating: 0, count: 48_000)
                    return [.init(track: .system, samples: Array(padded.prefix(end).suffix(480_000)), endFrame: Int64(end))]
                }, update: { continuation.yield($0) })
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: UInt64(Double(samples.count) / 16_000 + 12) * 1_000_000_000)
                    await service.stop()
                    continuation.finish()
                }
                var partialCount = 0
                var finalCount = 0
                var finalText = ""
                for await event in events {
                    if let segment = event.segment {
                        print(String(format: "%.2fs", Date().timeIntervalSince(began)), segment.isFinal ? "FINAL" : "PARTIAL", segment.text)
                        if segment.isFinal { print("SOURCE:", segment.originalText); finalCount += 1; finalText += " " + segment.text }
                        else { partialCount += 1 }
                    } else { print(event.status) }
                    fflush(stdout)
                }
                timeout.cancel()
                guard partialCount > 0, finalCount > 0, (externalFixture != nil || finalText.lowercased().contains("design")) else {
                    throw CallScribeBackendError.unavailable("Azure check did not return expected incremental English translation.")
                }
                print("PASS: \(partialCount) partials, \(finalCount) finals. Audio fixture streamed to Azure; no live inputs opened.")
                exit(0)
            } catch {
                fputs("Diagnostic failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        return true
    }

    private struct Configuration: Decodable { var key: String; var region: String }
    private static let examples = [
        "We can review the project budget together next week.",
        "The camera needs to count pedestrians, bicycles and vehicles at the intersection.",
        "I’ll send the updated report on Friday so everyone can review the numbers.",
        "Could we keep the first version simple and add the dashboard afterwards?",
        "Yes, that works. Let’s confirm the timeline before we finish."
    ]
}
