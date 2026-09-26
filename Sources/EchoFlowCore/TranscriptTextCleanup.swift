import Foundation

public enum AppTranscriptWritingStyle: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case casual
    case clean
    case unchanged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .casual: "Casual"
        case .clean: "Clean"
        case .unchanged: "No changes"
        }
    }
}

public struct AppTextCleanupProfile: Codable, Equatable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public var displayName: String
    public var style: AppTranscriptWritingStyle

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String, style: AppTranscriptWritingStyle) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.style = style
    }
}

public struct TranscriptTextCleanupSettings: Codable, Equatable, Sendable {
    public var removeFillerWords: Bool
    public var removeFalseStarts: Bool
    public var convertSpokenNumbersToDigits: Bool
    public var aiCleanupEnabled: Bool
    public private(set) var applicationProfiles: [AppTextCleanupProfile]

    public init(
        removeFillerWords: Bool = false,
        removeFalseStarts: Bool = false,
        convertSpokenNumbersToDigits: Bool = false,
        aiCleanupEnabled: Bool = false,
        applicationProfiles: [AppTextCleanupProfile] = Self.defaultApplicationProfiles
    ) {
        self.removeFillerWords = removeFillerWords
        self.removeFalseStarts = removeFalseStarts
        self.convertSpokenNumbersToDigits = convertSpokenNumbersToDigits
        self.aiCleanupEnabled = aiCleanupEnabled
        self.applicationProfiles = Self.normalizedProfiles(applicationProfiles)
    }

    public static let defaultApplicationProfiles: [AppTextCleanupProfile] = [
        AppTextCleanupProfile(bundleIdentifier: "com.apple.MobileSMS", displayName: "Messages", style: .casual),
        AppTextCleanupProfile(bundleIdentifier: "md.obsidian", displayName: "Obsidian", style: .clean),
        AppTextCleanupProfile(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            displayName: "Claude",
            style: .clean
        ),
        AppTextCleanupProfile(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", style: .unchanged)
    ]

    public func style(forBundleIdentifier bundleIdentifier: String?) -> AppTranscriptWritingStyle {
        guard let bundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else { return .clean }
        return applicationProfiles.first(where: {
            Self.normalizedBundleIdentifier($0.bundleIdentifier) == bundleIdentifier
        })?.style ?? .clean
    }

    public mutating func setStyle(_ style: AppTranscriptWritingStyle, for profile: AppTextCleanupProfile) {
        let identifier = Self.normalizedBundleIdentifier(profile.bundleIdentifier) ?? profile.bundleIdentifier
        if let index = applicationProfiles.firstIndex(where: {
            Self.normalizedBundleIdentifier($0.bundleIdentifier) == identifier
        }) {
            applicationProfiles[index].displayName = profile.displayName
            applicationProfiles[index].style = style
        } else {
            applicationProfiles.append(AppTextCleanupProfile(
                bundleIdentifier: identifier,
                displayName: profile.displayName,
                style: style
            ))
        }
        applicationProfiles = Self.normalizedProfiles(applicationProfiles)
    }

    public mutating func removeProfile(bundleIdentifier: String) {
        guard let identifier = Self.normalizedBundleIdentifier(bundleIdentifier) else { return }
        applicationProfiles.removeAll {
            Self.normalizedBundleIdentifier($0.bundleIdentifier) == identifier
        }
    }

    private static func normalizedProfiles(_ profiles: [AppTextCleanupProfile]) -> [AppTextCleanupProfile] {
        var seen = Set<String>()
        return profiles.compactMap { profile in
            guard let identifier = normalizedBundleIdentifier(profile.bundleIdentifier),
                  !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(identifier).inserted else { return nil }
            return AppTextCleanupProfile(
                bundleIdentifier: identifier,
                displayName: profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                style: profile.style
            )
        }
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

public struct TranscriptCleanupPlan: Equatable, Sendable {
    public let rawText: String
    public let text: String
    public let aiStyle: AppTranscriptWritingStyle?

    public init(rawText: String, text: String, aiStyle: AppTranscriptWritingStyle?) {
        self.rawText = rawText
        self.text = text
        self.aiStyle = aiStyle
    }
}

public enum TranscriptTextCleanupPolicy {
    private static let fillerPattern = #"(?i)(?<![\p{L}\p{N}_])(?:um+|uh+)(?![\p{L}\p{N}_])[,;:]?"#
    private static let parentheticalLikePattern = #"(?i),[ \t]*like,[ \t]*"#
    private static let leadingLikePattern = #"(?i)^\s*like,[ \t]*"#
    private static let repeatedLikePattern = #"(?i)(?<![\p{L}\p{N}_])([\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?),[ \t]*like,[ \t]*\1(?![\p{L}\p{N}_])"#
    private static let repeatedPhrasePattern = #"(?i)(?<![\p{L}\p{N}_])((?:[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?[ \t]+){0,5}[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?)(?:[,;:—–-])[ \t]*\1(?![\p{L}\p{N}_])"#
    private static let repeatedWordPattern = #"(?i)(?<![\p{L}\p{N}_])([\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?)[ \t]+\1(?![\p{L}\p{N}_])"#
    private static let numberWordPattern = #"(?i)[\p{L}]+"#

    private static let smallNumbers: [String: Int64] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tens: [String: Int64] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let ordinalSmallNumbers: [String: Int64] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19
    ]
    private static let ordinalTens: [String: Int64] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90
    ]

    public static func plan(
        _ text: String,
        settings: TranscriptTextCleanupSettings,
        targetBundleIdentifier: String?
    ) -> TranscriptCleanupPlan {
        let style = settings.style(forBundleIdentifier: targetBundleIdentifier)
        guard style != .unchanged else {
            return TranscriptCleanupPlan(rawText: text, text: text, aiStyle: nil)
        }
        let cleanedText = apply(text, settings: settings)
        return TranscriptCleanupPlan(
            rawText: text,
            text: cleanedText,
            aiStyle: settings.aiCleanupEnabled ? style : nil
        )
    }

    public static func apply(_ text: String, settings: TranscriptTextCleanupSettings) -> String {
        var result = text
        if settings.removeFalseStarts {
            result = removingFalseStarts(from: result)
        }
        if settings.removeFillerWords {
            result = removingFillers(from: result)
        }
        if settings.convertSpokenNumbersToDigits {
            result = convertingSpokenNumbers(in: result)
        }
        return result
    }

    private static func removingFalseStarts(from text: String) -> String {
        var result = replacing(repeatedPhrasePattern, in: text, with: "$1")
        result = replacing(repeatedWordPattern, in: result, with: "$1")
        return result
    }

    private static func removingFillers(from text: String) -> String {
        var result = replacing(repeatedLikePattern, in: text, with: "$1, $1")
        result = replacing(parentheticalLikePattern, in: result, with: " ")
        result = replacing(leadingLikePattern, in: result, with: "")
        result = replacing(fillerPattern, in: result, with: "")
        result = replacing(#"[ \t]+([,.;!?])"#, in: result, with: "$1")
        result = replacing(#"[,;:]+(?=[.!?])"#, in: result, with: "")
        result = replacing(#"([,;:!?])(?:[ \t]*[,;:!?])+"#, in: result, with: "$1")
        result = replacing(#"[ \t]{2,}"#, in: result, with: " ")
        result = replacing(#"^[,;:]+[ \t]*"#, in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct WordToken {
        let value: String
        let range: NSRange
    }

    private struct ParsedNumber {
        let consumedWordCount: Int
        let replacement: String
    }

    private enum PreviousNumberComponent {
        case none
        case small
        case tens
        case hundred
        case scale
        case conjunction
        case decimal
        case decimalDigit
        case sign
    }

    private static func convertingSpokenNumbers(in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: numberWordPattern, options: []) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let tokens = expression.matches(in: text, range: fullRange).compactMap { match -> WordToken? in
            guard let range = Range(match.range, in: text) else { return nil }
            return WordToken(value: String(text[range]).lowercased(), range: match.range)
        }
        guard !tokens.isEmpty else { return text }

        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < tokens.count {
            guard let parsed = parseNumber(tokens, startingAt: index, in: text), parsed.consumedWordCount > 0 else {
                index += 1
                continue
            }
            let start = tokens[index].range.location
            let last = tokens[index + parsed.consumedWordCount - 1]
            replacements.append((NSRange(location: start, length: NSMaxRange(last.range) - start), parsed.replacement))
            index += parsed.consumedWordCount
        }

        let mutableText = NSMutableString(string: text)
        for (range, replacement) in replacements.reversed() {
            mutableText.replaceCharacters(in: range, with: replacement)
        }
        return mutableText as String
    }

    private static func parseNumber(
        _ tokens: [WordToken],
        startingAt start: Int,
        in source: String
    ) -> ParsedNumber? {
        var total: Int64 = 0
        var current: Int64 = 0
        var decimalDigits = ""
        var consumed = 0
        var isNegative = false
        var hasIntegerNumber = false
        var isDecimal = false
        var isOrdinal = false
        var previous = PreviousNumberComponent.none
        var index = start

        while index < tokens.count {
            if isOrdinal { break }
            let token = tokens[index]
            if consumed > 0 {
                let previousToken = tokens[index - 1]
                let gap = (source as NSString).substring(with: NSRange(
                    location: NSMaxRange(previousToken.range),
                    length: token.range.location - NSMaxRange(previousToken.range)
                ))
                guard isNumberWordSeparator(gap) else { break }
            }

            let word = token.value
            if word == "negative" || word == "minus" {
                guard consumed == 0 else { break }
                isNegative = true
                previous = .sign
                consumed += 1
                index += 1
                continue
            }
            if word == "and" {
                guard hasIntegerNumber, !isDecimal, index + 1 < tokens.count,
                      isNumberWord(tokens[index + 1].value),
                      hasOnlyWhitespaceBetween(tokens[index], tokens[index + 1], source: source) else { break }
                previous = .conjunction
                consumed += 1
                index += 1
                continue
            }
            if word == "point" || word == "decimal" {
                guard hasIntegerNumber, !isDecimal, index + 1 < tokens.count,
                      let digit = smallNumbers[tokens[index + 1].value], (0...9).contains(digit),
                      hasOnlyWhitespaceBetween(tokens[index], tokens[index + 1], source: source) else { break }
                isDecimal = true
                previous = .decimal
                consumed += 1
                index += 1
                continue
            }

            if isDecimal {
                guard let digit = smallNumbers[word], (0...9).contains(digit) else { break }
                decimalDigits.append(String(digit))
                previous = .decimalDigit
                consumed += 1
                index += 1
                continue
            }

            if let value = ordinalSmallNumbers[word] {
                if previous == .small || (previous == .tens && value >= 10) { break }
                current += value
                hasIntegerNumber = true
                previous = .small
                isOrdinal = true
                consumed += 1
                index += 1
                continue
            }
            if let value = ordinalTens[word] {
                guard previous != .small else { break }
                current += value
                hasIntegerNumber = true
                previous = .tens
                isOrdinal = true
                consumed += 1
                index += 1
                continue
            }
            if word == "hundredth" {
                guard previous == .small || previous == .conjunction || previous == .none,
                      current <= Int64.max / 100 else { break }
                current = max(current, 1) * 100
                hasIntegerNumber = true
                previous = .hundred
                isOrdinal = true
                consumed += 1
                index += 1
                continue
            }
            if let scale = ordinalScaleValue(for: word) {
                guard current <= Int64.max / scale,
                      total <= Int64.max - max(current, 1) * scale else { break }
                total += max(current, 1) * scale
                current = 0
                hasIntegerNumber = true
                previous = .scale
                isOrdinal = true
                consumed += 1
                index += 1
                continue
            }

            if let value = smallNumbers[word] {
                if previous == .small { break }
                if previous == .tens, value >= 10 { break }
                current += value
                hasIntegerNumber = true
                previous = .small
                consumed += 1
                index += 1
                continue
            }
            if let value = tens[word] {
                guard previous != .small else { break }
                current += value
                hasIntegerNumber = true
                previous = .tens
                consumed += 1
                index += 1
                continue
            }
            if word == "hundred" {
                guard previous == .small || previous == .conjunction || previous == .none,
                      current <= Int64.max / 100 else { break }
                current = max(current, 1) * 100
                hasIntegerNumber = true
                previous = .hundred
                consumed += 1
                index += 1
                continue
            }
            if let scale = scaleValue(for: word) {
                guard previous != .none, previous != .sign, previous != .decimal,
                      current <= Int64.max / scale,
                      total <= Int64.max - current * scale else { break }
                total += max(current, 1) * scale
                current = 0
                hasIntegerNumber = true
                previous = .scale
                consumed += 1
                index += 1
                continue
            }
            break
        }

        guard hasIntegerNumber, consumed > 0, previous != .sign else { return nil }
        let integer = total + current
        let signed = isNegative ? -integer : integer
        let integerText = String(signed)
        let decimalText = decimalDigits.isEmpty ? "" : "." + decimalDigits
        let ordinalText = isOrdinal ? ordinalSuffix(for: signed) : ""
        return ParsedNumber(consumedWordCount: consumed, replacement: integerText + decimalText + ordinalText)
    }

    private static func isNumberWord(_ word: String) -> Bool {
        smallNumbers[word] != nil
            || tens[word] != nil
            || ordinalSmallNumbers[word] != nil
            || ordinalTens[word] != nil
            || word == "hundred"
            || word == "hundredth"
            || scaleValue(for: word) != nil
            || ordinalScaleValue(for: word) != nil
    }

    private static func isNumberWordSeparator(_ gap: String) -> Bool {
        guard !gap.contains("\n"), !gap.contains("\r") else { return false }
        return gap.allSatisfy { $0.isWhitespace || $0 == "-" }
    }

    private static func hasOnlyWhitespaceBetween(_ first: WordToken, _ second: WordToken, source: String) -> Bool {
        let gap = (source as NSString).substring(with: NSRange(
            location: NSMaxRange(first.range),
            length: second.range.location - NSMaxRange(first.range)
        ))
        return gap.allSatisfy(\.isWhitespace)
    }

    private static func scaleValue(for word: String) -> Int64? {
        switch word {
        case "thousand": 1_000
        case "million": 1_000_000
        case "billion": 1_000_000_000
        default: nil
        }
    }

    private static func ordinalScaleValue(for word: String) -> Int64? {
        switch word {
        case "thousandth": 1_000
        case "millionth": 1_000_000
        case "billionth": 1_000_000_000
        default: nil
        }
    }

    private static func ordinalSuffix(for value: Int64) -> String {
        let magnitude = abs(value)
        let lastTwoDigits = magnitude % 100
        if (11...13).contains(lastTwoDigits) { return "th" }
        return switch magnitude % 10 {
        case 1: "st"
        case 2: "nd"
        case 3: "rd"
        default: "th"
        }
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

public enum TranscriptAIOutputPolicy {
    public static func deliveredText(
        _ candidate: String?,
        preparedText: String,
        fallbackText: String
    ) -> String {
        guard let candidate,
              let accepted = acceptedCandidate(candidate, original: preparedText) else {
            return fallbackText
        }
        return accepted
    }

    public static func acceptedCandidate(_ candidate: String, original: String) -> String? {
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let maximumLength = max(200, original.count * 2 + 80)
        guard cleaned.count <= maximumLength else { return nil }
        return cleaned
    }
}
