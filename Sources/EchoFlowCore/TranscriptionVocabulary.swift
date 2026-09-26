import Foundation

/// Deterministic phrase selection shared by local transcription backends.
public enum TranscriptionVocabulary {
    /// Apple's contextual-string API accepts a bounded list of phrases.
    public static let applePhraseLimit = 100

    /// Pinned learned terms outrank explicit dictionary entries, which outrank
    /// unpinned learned terms. Duplicate and blank entries are removed.
    public static func terms(
        customTerms: [String],
        learnedTerms: [LocalLearnedTerm],
        maximumCount: Int = applePhraseLimit
    ) -> [String] {
        guard maximumCount > 0 else { return [] }
        let candidates = learnedTerms.filter(\.isPinned).map(\.term)
            + customTerms
            + learnedTerms.filter { !$0.isPinned }.map(\.term)
        var seen = Set<String>()
        var result: [String] = []

        for candidate in candidates {
            let cleaned = candidate
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !cleaned.isEmpty,
                  seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == maximumCount { break }
        }
        return result
    }

    /// Creates the plain-text vocabulary prompt consumed by WhisperKit's
    /// decoder prompt-token encoder.
    public static func whisperPromptText(from terms: [String]) -> String {
        terms.joined(separator: ", ")
    }
}
