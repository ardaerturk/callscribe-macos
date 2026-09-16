import Foundation

struct TimedTranscriptWord: Equatable, Sendable {
    let text: String
    let source: TranscriptSource
    let rawSpeakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double
}

enum TranscriptAssembler {
    private static let localSpeakerID = "__you__"
    private static let fallbackRemoteSpeakerID = "__remote__"
    private static let paragraphGap: TimeInterval = 1.1
    private static let sentenceGap: TimeInterval = 0.3
    private static let echoTimeTolerance: TimeInterval = 0.8

    static func words(
        from recognition: SpeechRecognitionResult,
        source: TranscriptSource,
        chunkStart: TimeInterval,
        chunkDuration: TimeInterval,
        diarization: [DiarizedSpeakerInterval]
    ) -> [TimedTranscriptWord] {
        let cleanResultText = collapseWhitespace(recognition.text)
        let sourceWords: [RecognizedWord]
        if recognition.words.isEmpty {
            guard !cleanResultText.isEmpty else { return [] }
            sourceWords = [
                RecognizedWord(
                    text: cleanResultText,
                    startTime: 0,
                    endTime: max(0, chunkDuration),
                    confidence: recognition.confidence
                )
            ]
        } else {
            sourceWords = recognition.words
        }

        return sourceWords.compactMap { word in
            let text = collapseWhitespace(word.text)
            guard !text.isEmpty else { return nil }
            let relativeStart = min(max(0, word.startTime), max(0, chunkDuration))
            let relativeEnd = min(
                max(relativeStart, word.endTime),
                max(relativeStart, chunkDuration)
            )
            let start = chunkStart + relativeStart
            let end = chunkStart + relativeEnd
            let speakerID: String
            switch source {
            case .microphone:
                speakerID = localSpeakerID
            case .meetingAudio:
                speakerID = bestSpeaker(
                    start: start,
                    end: end,
                    in: diarization
                ) ?? fallbackRemoteSpeakerID
            }
            return TimedTranscriptWord(
                text: text,
                source: source,
                rawSpeakerID: speakerID,
                startTime: start,
                endTime: end,
                confidence: min(1, max(0, word.confidence))
            )
        }
    }

    static func assemble(
        words: [TimedTranscriptWord],
        sessionID: UUID,
        recordedAt: Date,
        generatedAt: Date = Date(),
        recordingNotes: [String] = []
    ) -> MeetingTranscript {
        let drafts = group(words.sorted(by: wordSort))
        let withoutEcho = removeEchoDuplicates(from: drafts)
        let labeled = labelAndMerge(withoutEcho)
        let segments = labeled.enumerated().map { index, draft in
            TranscriptSegment(
                id: String(format: "segment-%06d", index + 1),
                speaker: draft.speaker,
                source: draft.source,
                startTime: draft.startTime,
                endTime: draft.endTime,
                text: draft.text,
                confidence: draft.confidence
            )
        }
        return MeetingTranscript(
            sessionID: sessionID,
            recordedAt: recordedAt,
            generatedAt: generatedAt,
            segments: segments,
            recordingNotes: recordingNotes
        )
    }

    private struct Draft: Equatable {
        var rawSpeakerID: String
        var speaker: String
        var source: TranscriptSource
        var startTime: TimeInterval
        var endTime: TimeInterval
        var text: String
        var confidenceTotal: Double
        var wordCount: Int

        var confidence: Double {
            guard wordCount > 0 else { return 0 }
            return confidenceTotal / Double(wordCount)
        }
    }

    private static func group(_ words: [TimedTranscriptWord]) -> [Draft] {
        var result: [Draft] = []
        var latestDraftByStream: [String: Int] = [:]
        for word in words {
            let streamKey = "\(word.source.rawValue)|\(word.rawSpeakerID)"
            if let previousIndex = latestDraftByStream[streamKey] {
                var last = result[previousIndex]
                let gap = word.startTime - last.endTime
                let sentenceEnded = endsSentence(last.text)
                if gap <= paragraphGap && !(sentenceEnded && gap > sentenceGap) {
                    last.text = append(word.text, to: last.text)
                    last.endTime = max(last.endTime, word.endTime)
                    last.confidenceTotal += word.confidence
                    last.wordCount += 1
                    result[previousIndex] = last
                    continue
                }
            }

            result.append(Draft(
                rawSpeakerID: word.rawSpeakerID,
                speaker: "",
                source: word.source,
                startTime: word.startTime,
                endTime: max(word.startTime, word.endTime),
                text: word.text,
                confidenceTotal: word.confidence,
                wordCount: 1
            ))
            latestDraftByStream[streamKey] = result.count - 1
        }
        return result.sorted(by: draftSort)
    }

    /// Playback can leak into the microphone when speakers are used. Keep the
    /// direct meeting-audio copy and remove the matching microphone echo.
    private static func removeEchoDuplicates(from drafts: [Draft]) -> [Draft] {
        let remote = drafts.filter { $0.source == .meetingAudio }
        return drafts.filter { candidate in
            guard candidate.source == .microphone else { return true }
            return !remote.contains { direct in
                normalizedWords(candidate.text).count >= 2 &&
                isTimeAligned(candidate, direct) && textSimilarity(candidate.text, direct.text) >= 0.9
            }
        }
    }

    private static func labelAndMerge(_ drafts: [Draft]) -> [Draft] {
        var speakerNames: [String: String] = [:]
        var nextSpeaker = 1
        var labeled: [Draft] = []

        for var draft in drafts.sorted(by: draftSort) {
            if draft.source == .microphone {
                draft.speaker = "You"
            } else {
                if speakerNames[draft.rawSpeakerID] == nil {
                    speakerNames[draft.rawSpeakerID] = "Speaker \(nextSpeaker)"
                    nextSpeaker += 1
                }
                draft.speaker = speakerNames[draft.rawSpeakerID]!
            }

            if var last = labeled.last,
               last.source == draft.source,
               last.speaker == draft.speaker,
               draft.startTime - last.endTime <= sentenceGap {
                last.text = append(draft.text, to: last.text)
                last.endTime = max(last.endTime, draft.endTime)
                last.confidenceTotal += draft.confidenceTotal
                last.wordCount += draft.wordCount
                labeled[labeled.count - 1] = last
            } else {
                labeled.append(draft)
            }
        }
        return labeled
    }

    private static func bestSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        in intervals: [DiarizedSpeakerInterval]
    ) -> String? {
        // RNNT punctuation can be emitted at the next sentence, stretching the
        // preceding word across a pause. Anchor attribution to the word's first
        // emission rather than allowing that delayed punctuation to select the
        // next speaker.
        let end = min(end, start + 0.35)
        let midpoint = start + max(0, end - start) / 2
        let ranked = intervals.map { interval -> (String, TimeInterval, TimeInterval) in
            let overlap = max(0, min(end, interval.endTime) - max(start, interval.startTime))
            let distance: TimeInterval
            if midpoint < interval.startTime {
                distance = interval.startTime - midpoint
            } else if midpoint > interval.endTime {
                distance = midpoint - interval.endTime
            } else {
                distance = 0
            }
            return (interval.speakerID, overlap, distance)
        }
        guard let best = ranked.max(by: { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 > rhs.2
        }) else { return nil }
        return best.1 > 0 || best.2 <= 0.75 ? best.0 : nil
    }

    private static func isTimeAligned(_ lhs: Draft, _ rhs: Draft) -> Bool {
        let overlap = max(0, min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime))
        if overlap > 0 { return true }
        let lhsMidpoint = (lhs.startTime + lhs.endTime) / 2
        let rhsMidpoint = (rhs.startTime + rhs.endTime) / 2
        return abs(lhsMidpoint - rhsMidpoint) <= echoTimeTolerance
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedWords(lhs)
        let right = normalizedWords(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }

        var rightCounts: [String: Int] = [:]
        for word in right { rightCounts[word, default: 0] += 1 }
        var common = 0
        for word in left where (rightCounts[word] ?? 0) > 0 {
            common += 1
            rightCounts[word, default: 0] -= 1
        }
        return Double(2 * common) / Double(left.count + right.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func append(_ token: String, to text: String) -> String {
        guard let first = token.first else { return text }
        if ",.!?;:%)]}".contains(first) {
            return text + token
        }
        if text.isEmpty || "([{\"".contains(text.last!) {
            return text + token
        }
        return text + " " + token
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    private static func wordSort(_ lhs: TimedTranscriptWord, _ rhs: TimedTranscriptWord) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.source != rhs.source { return lhs.source == .microphone }
        return lhs.endTime < rhs.endTime
    }

    private static func draftSort(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.source != rhs.source { return lhs.source == .microphone }
        return lhs.endTime < rhs.endTime
    }
}
