import CallScribeCore
import CallScribeTranscription
import Foundation

/// Saved-audio transcription is independent of the live caption toggle and budget.
/// Responses are cached before export, so retries do not repeat successful billing.
actor AzureSavedTranscriptService {
    struct Response: Codable {
        let phrases: [Phrase]
        struct Phrase: Codable {
            let text: String
            let channel: Int?
            let offsetMilliseconds: Double
            let durationMilliseconds: Double
            let confidence: Double?
        }
    }

    func transcribe(_ session: RecordingSession, region: String, formatting: TranscriptFormatting,
                    progress: @escaping @Sendable (Double?) -> Void) async throws -> TranscriptResult {
        let directory = session.directoryURL
        let cache = directory.appendingPathComponent("azure-transcript-response.json")
        let stateURL = directory.appendingPathComponent(TranscriptFileNames.processingState)
        func state(_ phase: TranscriptProcessingPhase, _ value: Double, _ message: String? = nil) throws {
            let state = TranscriptProcessingState(sessionID: session.id, phase: phase, progress: value,
                message: message, outputFiles: phase == .completed ? ["transcript.txt", "transcript.md", "transcript.json"] : [])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            progress(value)
        }
        do {
            try state(.validating, 0.02, "Preparing saved transcription")
            let data: Data
            if let existing = try? Data(contentsOf: cache) {
                data = existing
            } else {
                guard let key = try AzureCredentialStore.read(), !key.isEmpty else {
                    throw CallScribeBackendError.unavailable("Add your Azure Speech key in Settings to transcribe saved calls")
                }
                let normalizedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalizedRegion.isEmpty, normalizedRegion.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                    throw CallScribeBackendError.unavailable("Enter a valid Azure Speech region in Settings")
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CallScribe-upload-\(UUID())")
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let audio = temporary.appendingPathComponent("saved-call.wav")
                try state(.loadingAudio, 0.1, "Preparing both saved audio tracks")
                _ = try SavedAudioTimeline.writeStereo(session: session, to: audio)
                let boundary = "CallScribe-\(UUID())"
                let locales: [String]
                switch session.manifest.language {
                case .english: locales = ["en-US"]
                case .german: locales = ["de-DE"]
                case .turkish: locales = ["tr-TR"]
                }
                let definition = try JSONSerialization.data(withJSONObject: ["locales": locales, "channels": [0, 1]])
                let upload = temporary.appendingPathComponent("request.multipart")
                FileManager.default.createFile(atPath: upload.path, contents: nil)
                let body = try FileHandle(forWritingTo: upload)
                defer { try? body.close() }
                try body.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\nContent-Type: application/json\r\n\r\n".utf8))
                try body.write(contentsOf: definition)
                try body.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"saved-call.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
                let input = try FileHandle(forReadingFrom: audio)
                defer { try? input.close() }
                while let bytes = try input.read(upToCount: 262_144), !bytes.isEmpty {
                    try Task.checkCancellation(); try body.write(contentsOf: bytes)
                }
                try body.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)); try body.synchronize()
                var request = URLRequest(url: URL(string: "https://\(normalizedRegion).api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")!)
                request.httpMethod = "POST"
                request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 180
                configuration.timeoutIntervalForResource = 300
                let client = URLSession(configuration: configuration)
                defer { client.invalidateAndCancel() }
                try state(.transcribing, 0.35, "Uploading and transcribing in Azure; audio remains saved locally")
                let (received, response) = try await client.upload(for: request, fromFile: upload)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 422 {
                        throw CallScribeBackendError.unavailable("Azure found no recognizable speech in the saved audio. Check the session audio and meeting language before retrying; the recording is preserved.")
                    }
                    throw CallScribeBackendError.unavailable("Azure saved transcription failed (HTTP \(code)). Audio is safe; check the key, region and Azure quota, then retry.")
                }
                _ = try JSONDecoder().decode(Response.self, from: received)
                try received.write(to: cache, options: .atomic)
                data = received
            }
            try state(.writing, 0.9, "Saving the transcript")
            let result = try Self.export(data, session: session, formatting: formatting)
            try state(.completed, 1)
            return result
        } catch {
            try? state(.failed, 0, error.localizedDescription)
            throw error
        }
    }

    static func export(_ data: Data, session: RecordingSession, formatting: TranscriptFormatting) throws -> TranscriptResult {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let phrases = response.phrases.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.offsetMilliseconds < $1.offsetMilliseconds }
        guard !phrases.isEmpty else { throw CallScribeBackendError.noTranscript }
        let segments = phrases.enumerated().map { index, phrase in
            TranscriptSegment(id: "azure-\(index)", speaker: phrase.channel == 0 ? "You" : "Call",
                source: phrase.channel == 0 ? .microphone : .meetingAudio,
                startTime: phrase.offsetMilliseconds / 1_000,
                endTime: (phrase.offsetMilliseconds + phrase.durationMilliseconds) / 1_000,
                text: phrase.text, confidence: phrase.confidence ?? 1)
        }
        var notes = ["Machine transcript of both saved audio tracks using Azure. Call participants share the Call label."]
        if !segments.contains(where: { $0.source == .meetingAudio }) {
            notes.append("No speech was recognized on the saved call-audio track.")
        }
        if !segments.contains(where: { $0.source == .microphone }) {
            notes.append("No speech was recognized on the saved microphone track.")
        }
        for event in session.manifest.events where [.sleep, .wake, .warning, .captureStalled, .captureRestartFailed].contains(event.kind) {
            let note = ISO8601DateFormatter().string(from: event.date) + " — " + event.message
            if !notes.contains(note) { notes.append(note) }
        }
        let transcript = MeetingTranscript(sessionID: session.id, recordedAt: session.manifest.createdAt,
            languageCode: session.manifest.language.rawValue, segments: segments, recordingNotes: notes)
        let format: TranscriptTextFormat = formatting == .timestamped ? .timestamped : formatting == .plainText ? .plainText : .readable
        let text = transcript.rendered(as: format)
        let url = session.directoryURL.appendingPathComponent("transcript.txt")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: session.directoryURL.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(transcript.markdown.utf8).write(to: session.directoryURL.appendingPathComponent("transcript.md"), options: .atomic)
        try Data(text.utf8).write(to: url, options: .atomic)
        return TranscriptResult(text: text, textFileURL: url, sessionDirectoryURL: session.directoryURL)
    }
}
