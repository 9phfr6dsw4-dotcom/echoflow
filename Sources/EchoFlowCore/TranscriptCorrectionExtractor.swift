import Foundation

public struct TranscriptCorrection: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

/// Extracts only conservative, one-word edits from two transcript versions.
public enum TranscriptCorrectionExtractor {
    /// Compares an original transcript with its corrected version.
    ///
    /// Only uniquely aligned one-token-to-one-token changes are returned.
    /// Insertions, deletions, multi-token changes, and common or short words
    /// are not reported as corrections.
    public static func extract(from original: String, to corrected: String) -> [TranscriptCorrection] {
        let originalTokens = tokenize(original)
        let correctedTokens = tokenize(corrected)
        let originalCount = originalTokens.count
        let correctedCount = correctedTokens.count

        guard originalCount > 0, correctedCount > 0 else { return [] }

        // Suffix and prefix LCS tables identify every token match that can
        // participate in an optimal alignment.
        var suffixLengths = Array(
            repeating: Array(repeating: 0, count: correctedCount + 1),
            count: originalCount + 1
        )
        for originalIndex in (0..<originalCount).reversed() {
            for correctedIndex in (0..<correctedCount).reversed() {
                if originalTokens[originalIndex].normalized == correctedTokens[correctedIndex].normalized {
                    suffixLengths[originalIndex][correctedIndex] =
                        1 + suffixLengths[originalIndex + 1][correctedIndex + 1]
                } else {
                    suffixLengths[originalIndex][correctedIndex] = max(
                        suffixLengths[originalIndex + 1][correctedIndex],
                        suffixLengths[originalIndex][correctedIndex + 1]
                    )
                }
            }
        }

        let longestAlignmentLength = suffixLengths[0][0]

        var prefixLengths = Array(
            repeating: Array(repeating: 0, count: correctedCount + 1),
            count: originalCount + 1
        )
        for originalIndex in 0..<originalCount {
            for correctedIndex in 0..<correctedCount {
                if originalTokens[originalIndex].normalized == correctedTokens[correctedIndex].normalized {
                    prefixLengths[originalIndex + 1][correctedIndex + 1] =
                        1 + prefixLengths[originalIndex][correctedIndex]
                } else {
                    prefixLengths[originalIndex + 1][correctedIndex + 1] = max(
                        prefixLengths[originalIndex][correctedIndex + 1],
                        prefixLengths[originalIndex + 1][correctedIndex]
                    )
                }
            }
        }

        let alignment = uniqueAlignment(
            originalTokens: originalTokens,
            correctedTokens: correctedTokens,
            suffixLengths: suffixLengths,
            prefixLengths: prefixLengths,
            longestAlignmentLength: longestAlignmentLength
        )
        guard let alignment else { return [] }

        var corrections: [TranscriptCorrection] = []
        var originalCursor = 0
        var correctedCursor = 0

        for pair in alignment {
            appendCorrectionIfSingleToken(
                originalTokens: originalTokens,
                correctedTokens: correctedTokens,
                originalRange: originalCursor..<pair.originalIndex,
                correctedRange: correctedCursor..<pair.correctedIndex,
                to: &corrections
            )
            originalCursor = pair.originalIndex + 1
            correctedCursor = pair.correctedIndex + 1
        }

        appendCorrectionIfSingleToken(
            originalTokens: originalTokens,
            correctedTokens: correctedTokens,
            originalRange: originalCursor..<originalCount,
            correctedRange: correctedCursor..<correctedCount,
            to: &corrections
        )
        return corrections
    }

    private static func tokenize(_ text: String) -> [Token] {
        // Punctuation between words is ignored; apostrophes inside a word stay
        // with that token so contractions are not split into extra words.
        guard let expression = try? NSRegularExpression(
            pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*"
        ) else {
            return []
        }

        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        return expression.matches(in: text, range: fullRange).map { match in
            let surface = source.substring(with: match.range)
            let normalized = surface
                .precomposedStringWithCanonicalMapping
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            return Token(surface: surface, normalized: normalized)
        }
    }

    private static func uniqueAlignment(
        originalTokens: [Token],
        correctedTokens: [Token],
        suffixLengths: [[Int]],
        prefixLengths: [[Int]],
        longestAlignmentLength: Int
    ) -> [AlignmentPair]? {
        var alignment: [AlignmentPair] = []
        var originalStart = 0
        var correctedStart = 0
        var remainingLength = longestAlignmentLength

        // Select one optimal alignment, preferring the earliest possible
        // matching positions. The prefix/suffix tables below then prove it is
        // the only optimal alignment before any replacements are emitted.
        while remainingLength > 0 {
            var nextPair: AlignmentPair?
            search: for originalIndex in originalStart..<originalTokens.count {
                for correctedIndex in correctedStart..<correctedTokens.count {
                    guard originalTokens[originalIndex].normalized
                            == correctedTokens[correctedIndex].normalized,
                          suffixLengths[originalIndex + 1][correctedIndex + 1] + 1
                            == remainingLength else {
                        continue
                    }
                    nextPair = AlignmentPair(
                        originalIndex: originalIndex,
                        correctedIndex: correctedIndex
                    )
                    break search
                }
            }
            guard let nextPair else { return nil }
            alignment.append(nextPair)
            originalStart = nextPair.originalIndex + 1
            correctedStart = nextPair.correctedIndex + 1
            remainingLength -= 1
        }

        let selectedPairs = Set(alignment)
        for originalIndex in originalTokens.indices {
            for correctedIndex in correctedTokens.indices {
                guard originalTokens[originalIndex].normalized
                        == correctedTokens[correctedIndex].normalized,
                      prefixLengths[originalIndex][correctedIndex] + 1
                        + suffixLengths[originalIndex + 1][correctedIndex + 1]
                        == longestAlignmentLength else {
                    continue
                }
                let pair = AlignmentPair(
                    originalIndex: originalIndex,
                    correctedIndex: correctedIndex
                )
                if !selectedPairs.contains(pair) {
                    return nil
                }
            }
        }

        return alignment
    }

    private static func appendCorrectionIfSingleToken(
        originalTokens: [Token],
        correctedTokens: [Token],
        originalRange: Range<Int>,
        correctedRange: Range<Int>,
        to corrections: inout [TranscriptCorrection]
    ) {
        guard originalRange.count == 1,
              correctedRange.count == 1 else {
            return
        }

        let originalToken = originalTokens[originalRange.lowerBound]
        let correctedToken = correctedTokens[correctedRange.lowerBound]
        guard originalToken.normalized != correctedToken.normalized,
              isUsefulCorrection(originalToken.normalized),
              isUsefulCorrection(correctedToken.normalized) else {
            return
        }

        corrections.append(
            TranscriptCorrection(
                original: originalToken.surface,
                replacement: correctedToken.surface
            )
        )
    }

    private static func isUsefulCorrection(_ token: String) -> Bool {
        guard token.count >= 3, !commonWords.contains(token) else { return false }
        return true
    }

    private static let commonWords: Set<String> = Set(
        "a about above after again against all am an and any are as at be because been before being below between both but by can could did do does doing down during each few for from further had has have having he her here hers herself him himself his how i if in into is it its itself just me more most my myself no nor not now of off on once one only or other our ours ourselves out over own same she should so some such than that the their theirs them themselves then there these they this those through to too under until up very was we were what when where which while who whom why will with would you your yours yourself yourselves"
            .split(separator: " ")
            .map(String.init)
    )

    private struct Token {
        let surface: String
        let normalized: String
    }

    private struct AlignmentPair: Hashable {
        let originalIndex: Int
        let correctedIndex: Int
    }
}
