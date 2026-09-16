import ArgmaxCore
import Foundation
import WhisperKit

/// Uses only the local-folder parser, never the library's Hub fallback. This
/// adapter supports the whitespace-separated languages exposed by CallScribe.
final class LocalWhisperTokenizer: WhisperTokenizer {
    private let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static func load(from folder: URL) async throws -> LocalWhisperTokenizer {
        try await LocalWhisperTokenizer(base: AutoTokenizerWrapper.from(modelFolder: folder))
    }

    private init(base: TokenizerWrapper) throws {
        self.base = base
        func required(_ text: String) throws -> Int {
            guard let id = base.convertTokenToId(text) else { throw WhisperError.tokenizerUnavailable() }
            return id
        }
        specialTokens = try SpecialTokens(endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
            noSpeechToken: required("<|nospeech|>"), noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"),
            whitespaceToken: base.encode(text: " ", addSpecialTokens: false).first ?? 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { base.convertTokenToId("<|\($0)|>") })
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for (index, token) in tokenIds.enumerated() {
            pending.append(token)
            let piece = base.decode(tokens: pending)
            // Turkish dotted/dotless i, umlauts and other UTF-8 characters can
            // span byte-level tokens. Don't split while bytes are incomplete.
            if piece.contains("\u{fffd}"), index < tokenIds.count - 1 { continue }
            let punctuation = !piece.isEmpty && piece.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0)
            }
            if words.isEmpty || (pending.first ?? 0) >= specialTokens.specialTokenBegin
                || piece.first?.isWhitespace == true || punctuation {
                words.append(piece)
                groups.append(pending)
            } else {
                words[words.count - 1] += piece
                groups[groups.count - 1] += pending
            }
            pending = []
        }
        return (words, groups)
    }
}
