import CallScribeCore
import CallScribeTranscription
import Foundation

/// Optional terminal checks. These never open microphone or meeting inputs.
enum AppDiagnostics {
    @MainActor
    static func startIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--prepare-models") || arguments.contains("--verify-models") else { return false }
        Task {
            do {
                let processor = MeetingNotesProcessor()
                let download = arguments.contains("--prepare-models")
                print(download ? "Preparing local models…" : "Loading local models with downloads disabled…")
                try await processor.prepareModels(allowDownloads: download)
                if !download {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let directory = support.appendingPathComponent("CallScribe/Verification", isDirectory: true)
                    let store = try SessionStore(rootURL: directory.appendingPathComponent("Sessions"))
                    let recorder = try store.beginSession()
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
