import Foundation

/// Controls when explicit correction history is allowed to add a learned term.
public struct LocalLearningPolicy: Codable, Equatable, Sendable {
    /// The number of matching explicit corrections required before a term is proposed.
    public static let minimumCorrectionOccurrences = 3

    /// When enabled, threshold-reaching terms stay pending until explicitly confirmed.
    public var askBeforeAdding: Bool

    public init(askBeforeAdding: Bool = false) {
        self.askBeforeAdding = askBeforeAdding
    }
}

public enum LocalLearningObservation: Equatable, Sendable {
    case ignored
    case counted(occurrences: Int)
    case pendingConfirmation(term: String)
    case learned(term: String)
}

public struct LocalLearningPendingAddition: Codable, Equatable, Sendable {
    public let original: String
    public let term: String
    public let occurrenceCount: Int

    public init(original: String, term: String, occurrenceCount: Int) {
        self.original = original
        self.term = term
        self.occurrenceCount = occurrenceCount
    }
}

public struct LocalLearnedTerm: Codable, Equatable, Identifiable, Sendable {
    public let term: String
    public private(set) var occurrenceCount: Int
    public private(set) var isPinned: Bool

    public var id: String { term }

    fileprivate init(term: String, occurrenceCount: Int, isPinned: Bool = false) {
        self.term = term
        self.occurrenceCount = occurrenceCount
        self.isPinned = isPinned
    }
}

/// A deterministic, local-only collection of explicit correction observations.
/// This value is Codable so its state can be persisted independently of transcript history.
public struct LocalLearningStore: Codable, Equatable, Sendable {
    public var policy: LocalLearningPolicy
    public private(set) var learnedTerms: [LocalLearnedTerm]

    private var correctionCounts: [CorrectionCount]

    public var pendingAdditions: [LocalLearningPendingAddition] {
        correctionCounts
            .filter(\.isPending)
            .map {
                LocalLearningPendingAddition(
                    original: $0.original,
                    term: $0.replacement,
                    occurrenceCount: $0.occurrenceCount
                )
            }
            .sorted {
                let leftTerm = Self.normalized($0.term)
                let rightTerm = Self.normalized($1.term)
                if leftTerm != rightTerm { return leftTerm < rightTerm }
                return Self.normalized($0.original) < Self.normalized($1.original)
            }
    }

    public init(policy: LocalLearningPolicy = LocalLearningPolicy()) {
        self.policy = policy
        self.learnedTerms = []
        self.correctionCounts = []
    }

    /// Records one explicit original-to-replacement correction.
    /// Merely observing dictated text is not sufficient to call this method.
    @discardableResult
    public mutating func observeCorrection(
        original: String,
        replacement: String
    ) -> LocalLearningObservation {
        let cleanedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOriginal = Self.normalized(cleanedOriginal)
        let normalizedReplacement = Self.normalized(cleanedReplacement)

        guard !normalizedOriginal.isEmpty,
              !normalizedReplacement.isEmpty,
              Self.isLearnableTerm(cleanedReplacement) else {
            return .ignored
        }

        let correctionIndex: Int
        if let existingIndex = correctionCounts.firstIndex(where: {
            $0.normalizedOriginal == normalizedOriginal
                && $0.normalizedReplacement == normalizedReplacement
        }) {
            correctionIndex = existingIndex
            correctionCounts[existingIndex].occurrenceCount += 1
        } else {
            correctionIndex = correctionCounts.count
            correctionCounts.append(
                CorrectionCount(
                    original: cleanedOriginal,
                    replacement: cleanedReplacement,
                    normalizedOriginal: normalizedOriginal,
                    normalizedReplacement: normalizedReplacement,
                    occurrenceCount: 1,
                    isPending: false
                )
            )
        }

        if let learnedIndex = learnedTerms.firstIndex(where: {
            Self.normalized($0.term) == normalizedReplacement
        }) {
            let existing = learnedTerms[learnedIndex]
            learnedTerms[learnedIndex] = LocalLearnedTerm(
                term: existing.term,
                occurrenceCount: existing.occurrenceCount + 1,
                isPinned: existing.isPinned
            )
            correctionCounts[correctionIndex].isPending = false
            return .learned(term: existing.term)
        }

        let count = correctionCounts[correctionIndex].occurrenceCount
        guard count >= LocalLearningPolicy.minimumCorrectionOccurrences else {
            return .counted(occurrences: count)
        }

        if policy.askBeforeAdding {
            correctionCounts[correctionIndex].isPending = true
            return .pendingConfirmation(term: correctionCounts[correctionIndex].replacement)
        }

        correctionCounts[correctionIndex].isPending = false
        let term = correctionCounts[correctionIndex].replacement
        learnedTerms.append(LocalLearnedTerm(term: term, occurrenceCount: count))
        sortLearnedTerms()
        return .learned(term: term)
    }

    /// Adds a pending term after explicit user confirmation.
    @discardableResult
    public mutating func confirmAddition(of term: String) -> Bool {
        let normalizedTerm = Self.normalized(term)
        guard !normalizedTerm.isEmpty else { return false }
        let matchingIndices = correctionCounts.indices.filter {
            correctionCounts[$0].isPending
                && correctionCounts[$0].normalizedReplacement == normalizedTerm
        }
        guard !matchingIndices.isEmpty else { return false }

        if let existingIndex = learnedTerms.firstIndex(where: {
            Self.normalized($0.term) == normalizedTerm
        }) {
            let existing = learnedTerms[existingIndex]
            let additionalOccurrences = matchingIndices.reduce(0) {
                $0 + correctionCounts[$1].occurrenceCount
            }
            learnedTerms[existingIndex] = LocalLearnedTerm(
                term: existing.term,
                occurrenceCount: existing.occurrenceCount + additionalOccurrences,
                isPinned: existing.isPinned
            )
        } else {
            let firstPending = correctionCounts[matchingIndices[0]]
            let totalOccurrences = matchingIndices.reduce(0) {
                $0 + correctionCounts[$1].occurrenceCount
            }
            learnedTerms.append(
                LocalLearnedTerm(term: firstPending.replacement, occurrenceCount: totalOccurrences)
            )
            sortLearnedTerms()
        }

        for index in matchingIndices {
            correctionCounts[index].isPending = false
        }
        return true
    }

    /// Rejects pending proposals for this normalized term and resets their counters.
    @discardableResult
    public mutating func rejectAddition(of term: String) -> Bool {
        let normalizedTerm = Self.normalized(term)
        let previousCount = correctionCounts.count
        correctionCounts.removeAll {
            $0.isPending && $0.normalizedReplacement == normalizedTerm
        }
        return correctionCounts.count != previousCount
    }

    /// Pins or unpins a learned term. Returns false when the term is not learned.
    @discardableResult
    public mutating func setPinned(_ isPinned: Bool, for term: String) -> Bool {
        let normalizedTerm = Self.normalized(term)
        guard let index = learnedTerms.firstIndex(where: {
            Self.normalized($0.term) == normalizedTerm
        }) else {
            return false
        }

        let existing = learnedTerms[index]
        learnedTerms[index] = LocalLearnedTerm(
            term: existing.term,
            occurrenceCount: existing.occurrenceCount,
            isPinned: isPinned
        )
        return true
    }

    /// Removes a learned term and its accumulated proposal state.
    @discardableResult
    public mutating func removeLearnedTerm(_ term: String) -> Bool {
        let normalizedTerm = Self.normalized(term)
        let previousCount = learnedTerms.count
        learnedTerms.removeAll { Self.normalized($0.term) == normalizedTerm }
        guard learnedTerms.count != previousCount else { return false }
        correctionCounts.removeAll { $0.normalizedReplacement == normalizedTerm }
        return true
    }

    private mutating func sortLearnedTerms() {
        learnedTerms.sort {
            let leftTerm = Self.normalized($0.term)
            let rightTerm = Self.normalized($1.term)
            if leftTerm != rightTerm { return leftTerm < rightTerm }
            return $0.term < $1.term
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func isLearnableTerm(_ value: String) -> Bool {
        let stopwords: Set<String> = [
            "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
            "any", "are", "as", "at", "be", "because", "been", "before", "being", "below",
            "between", "both", "but", "by", "can", "could", "did", "do", "does", "doing",
            "down", "during", "each", "few", "for", "from", "further", "had", "has", "have",
            "having", "he", "her", "here", "hers", "herself", "him", "himself", "his", "how",
            "i", "if", "in", "into", "is", "it", "its", "itself", "just", "me", "more", "most",
            "my", "myself", "no", "nor", "not", "now", "of", "off", "on", "once", "one", "only",
            "or", "other", "our", "ours", "ourselves", "out", "over", "own", "same", "she", "should",
            "so", "some", "such", "than", "that", "the", "their", "theirs", "them", "themselves",
            "then", "there", "these", "they", "this", "those", "through", "to", "too", "under",
            "until", "up", "very", "was", "we", "were", "what", "when", "where", "which", "while",
            "who", "whom", "why", "will", "with", "would", "you", "your", "yours", "yourself",
            "yourselves"
        ]
        let words = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { word in
            let token = String(word)
            return token.count >= 3 && !stopwords.contains(token)
        }
    }

    private struct CorrectionCount: Codable, Equatable, Sendable {
        let original: String
        let replacement: String
        let normalizedOriginal: String
        let normalizedReplacement: String
        var occurrenceCount: Int
        var isPending: Bool
    }
}
