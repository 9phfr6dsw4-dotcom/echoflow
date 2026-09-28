import Foundation

/// One paragraph of a file transcript: when it starts, who is speaking (when speakers were
/// detected), and its text.
public struct TranscriptBlock: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerID: String?
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, speakerID: String?, text: String) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.text = text
    }
}

/// A stretch of audio where one speaker is talking, as found by speaker detection.
public struct SpeakerTurn: Equatable, Sendable {
    public let speakerID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Groups timed pieces into readable paragraphs. With speaker turns, a new paragraph starts
/// whenever the speaker changes; long turns and unlabeled transcripts are split at sentence ends.
public enum TranscriptBlockBuilder {
    /// Without speaker labels, a paragraph ends at the first sentence end after 30 seconds, or at
    /// the next word after 120 seconds.
    public static let paragraphTargetSeconds: TimeInterval = 30
    public static let paragraphLimitSeconds: TimeInterval = 120
    /// With speaker labels, one speaker's turn stays together longer.
    public static let speakerParagraphTargetSeconds: TimeInterval = 90
    public static let speakerParagraphLimitSeconds: TimeInterval = 180
    /// A single word given to a different speaker than the words on both sides of it is treated
    /// as a timing wobble when it is shorter than this.
    public static let speakerFlipMaximumSeconds: TimeInterval = 1
    /// A short run of words given to another speaker in the middle of someone's sentence, with no
    /// sentence end of its own, is treated as a detection wobble when it is no longer than this.
    public static let speakerBlipMaximumWords = 6
    public static let speakerBlipMaximumSeconds: TimeInterval = 2
    /// Speaker detection often marks a change a word or two late. A change that doesn't fall at a
    /// sentence end is moved back to the previous one within this many words and seconds.
    public static let speakerSnapMaximumWords = 12
    public static let speakerSnapMaximumSeconds: TimeInterval = 3.5
    /// A change is moved forward only when the new speaker's first word is lowercase (it reads as
    /// the rest of the previous sentence), and only this many words: otherwise the first speaker
    /// was probably cut off, and the new speaker's words would be given to them.
    public static let speakerForwardSnapMaximumWords = 2

    struct Word: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speakerID: String?
    }

    public static func blocks(from pieces: [TimedTextPiece], speakerTurns: [SpeakerTurn]) -> [TranscriptBlock] {
        var words = groupedWords(pieces)
        guard !words.isEmpty else { return [] }
        let turns = speakerTurns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let hasSpeakers = !turns.isEmpty
        if hasSpeakers {
            for index in words.indices {
                words[index].speakerID = speaker(forStart: words[index].start, end: words[index].end, in: turns)
            }
            smoothSpeakerFlips(&words)
            mergeMidSentenceBlips(&words)
            snapSpeakerChangesToSentences(&words)
        }
        let target = hasSpeakers ? speakerParagraphTargetSeconds : paragraphTargetSeconds
        let limit = hasSpeakers ? speakerParagraphLimitSeconds : paragraphLimitSeconds

        var blocks: [TranscriptBlock] = []
        var current: TranscriptBlock?
        var previousEndedSentence = false
        for word in words {
            if let block = current {
                let elapsed = word.start - block.start
                let speakerChanged = block.speakerID != word.speakerID
                if speakerChanged || (previousEndedSentence && elapsed >= target) || elapsed >= limit {
                    appendFinished(block, to: &blocks)
                    current = nil
                }
            }
            if var block = current {
                block.text += word.text
                block.end = max(block.end, word.end)
                current = block
            } else {
                current = TranscriptBlock(start: word.start, end: word.end, speakerID: word.speakerID, text: word.text)
            }
            previousEndedSentence = endsSentence(word.text)
        }
        if let current { appendFinished(current, to: &blocks) }
        return blocks
    }

    /// Joins pieces into whole words. A new word begins where there is whitespace between pieces,
    /// so sub-word tokens and trailing punctuation stay with their word.
    static func groupedWords(_ pieces: [TimedTextPiece]) -> [Word] {
        var words: [Word] = []
        for piece in pieces where !piece.text.isEmpty {
            let startsWord = words.isEmpty
                || (piece.text.first?.isWhitespace ?? false)
                || (words[words.count - 1].text.last?.isWhitespace ?? false)
            if startsWord {
                words.append(Word(text: piece.text, start: piece.start, end: piece.end, speakerID: nil))
            } else {
                words[words.count - 1].text += piece.text
                words[words.count - 1].end = max(words[words.count - 1].end, piece.end)
            }
        }
        return words
    }

    /// The speaker whose turn overlaps the word the most, or, for a word in a pause between
    /// turns, the speaker of the nearest turn.
    static func speaker(forStart start: TimeInterval, end: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        var nearest: (id: String, distance: TimeInterval)?
        let middle = (start + end) / 2
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 {
                if best == nil || overlap > best!.overlap { best = (turn.speakerID, overlap) }
                continue
            }
            let distance = middle < turn.start ? turn.start - middle : (middle > turn.end ? middle - turn.end : 0)
            if nearest == nil || distance < nearest!.distance { nearest = (turn.speakerID, distance) }
        }
        return best?.id ?? nearest?.id
    }

    static func smoothSpeakerFlips(_ words: inout [Word]) {
        guard words.count >= 3 else { return }
        for index in 1..<(words.count - 1) {
            let before = words[index - 1].speakerID
            let after = words[index + 1].speakerID
            // A one-word sentence of its own ("Yes.") is a real interjection, not a wobble.
            let isOwnSentence = endsSentence(words[index - 1].text) && endsSentence(words[index].text)
            if before == after, words[index].speakerID != before, !isOwnSentence,
               words[index].end - words[index].start < speakerFlipMaximumSeconds {
                words[index].speakerID = before
            }
        }
    }

    /// A short run of words given to another speaker in the middle of someone's sentence, with the
    /// same speaker on both sides and no sentence end of its own, goes back to the speaker around
    /// it. A run with its own sentence end ("Fine. Can you say more?") is a real interruption and
    /// is kept.
    static func mergeMidSentenceBlips(_ words: inout [Word]) {
        var start = 1
        while start < words.count {
            let surrounding = words[start - 1].speakerID
            guard surrounding != nil, words[start].speakerID != surrounding,
                  !endsSentence(words[start - 1].text) else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < words.count, words[end + 1].speakerID == words[start].speakerID {
                end += 1
            }
            let isBlip = end + 1 < words.count
                && words[end + 1].speakerID == surrounding
                && end - start + 1 <= speakerBlipMaximumWords
                && words[end].end - words[start].start <= speakerBlipMaximumSeconds
                && !words[start...end].contains(where: { endsSentence($0.text) })
            if isBlip {
                for position in start...end { words[position].speakerID = surrounding }
            }
            start = end + 1
        }
    }

    /// Moves each speaker change that doesn't fall at a sentence end: back to the previous sentence
    /// end (the new speaker's opening words were left with the previous speaker), otherwise forward
    /// by at most a word or two when those words continue the sentence in lowercase (the previous
    /// speaker's last words went to the new speaker). When neither applies, the first speaker was
    /// probably cut off, so the change stays where it is. A short turn that is a complete sentence
    /// ("Yes.") is left alone.
    static func snapSpeakerChangesToSentences(_ words: inout [Word]) {
        var index = 1
        while index < words.count {
            guard let previous = words[index - 1].speakerID, let next = words[index].speakerID,
                  previous != next, !endsSentence(words[index - 1].text) else {
                index += 1
                continue
            }
            var moved = false
            var candidate = index - 2
            while candidate >= 0,
                  index - 1 - candidate <= speakerSnapMaximumWords,
                  words[candidate].speakerID == previous,
                  words[index - 1].end - words[candidate + 1].start <= speakerSnapMaximumSeconds {
                if endsSentence(words[candidate].text) {
                    for position in (candidate + 1)...(index - 1) { words[position].speakerID = next }
                    moved = true
                    break
                }
                candidate -= 1
            }
            if !moved, startsLowercase(words[index].text) {
                var ahead = index
                while ahead < words.count,
                      ahead - index + 1 <= speakerForwardSnapMaximumWords,
                      words[ahead].speakerID == next,
                      words[ahead].end - words[index].start <= speakerSnapMaximumSeconds {
                    if endsSentence(words[ahead].text) {
                        if ahead + 1 < words.count, words[ahead + 1].speakerID == next {
                            for position in index...ahead { words[position].speakerID = previous }
                        }
                        break
                    }
                    ahead += 1
                }
            }
            index += 1
        }
    }

    private static func appendFinished(_ block: TranscriptBlock, to blocks: inout [TranscriptBlock]) {
        var finished = block
        finished.text = collapsedWhitespace(block.text)
        if !finished.text.isEmpty { blocks.append(finished) }
    }

    static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func startsLowercase(_ text: String) -> Bool {
        text.first(where: { !$0.isWhitespace })?.isLowercase ?? false
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace && $0 != "\"" && $0 != "”" && $0 != "'" && $0 != "’" && $0 != ")" }) else {
            return false
        }
        return ".?!…".contains(last)
    }
}

/// A finished file transcript, as shown on the Transcribe File tab and kept in Recent files.
public struct FileTranscriptDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What the user typed in the Title box. Empty means "use the file name".
    public var title: String
    public var sourceFileName: String
    public var duration: TimeInterval
    public var engineName: String
    public var createdAt: Date
    public var hasTimings: Bool
    public var blocks: [TranscriptBlock]
    /// Names the user typed for detected speakers, keyed by speaker ID. Missing or blank names
    /// fall back to "Speaker 1", "Speaker 2"… in order of first appearance.
    public var speakerNames: [String: String]
    public var subtitleSRT: String

    public init(
        id: UUID = UUID(),
        title: String,
        sourceFileName: String,
        duration: TimeInterval,
        engineName: String,
        createdAt: Date = Date(),
        hasTimings: Bool,
        blocks: [TranscriptBlock],
        speakerNames: [String: String] = [:],
        subtitleSRT: String
    ) {
        self.id = id
        self.title = title
        self.sourceFileName = sourceFileName
        self.duration = duration
        self.engineName = engineName
        self.createdAt = createdAt
        self.hasTimings = hasTimings
        self.blocks = blocks
        self.speakerNames = speakerNames
        self.subtitleSRT = subtitleSRT
    }

    public var displayTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let baseName = (sourceFileName as NSString).deletingPathExtension
        return baseName.isEmpty ? "Transcript" : baseName
    }

    /// Speaker IDs in the order they first speak.
    public var speakerIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for block in blocks {
            if let id = block.speakerID, seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }

    public var hasSpeakers: Bool { blocks.contains { $0.speakerID != nil } }

    public func defaultSpeakerName(for speakerID: String) -> String {
        guard let index = speakerIDs.firstIndex(of: speakerID) else { return "Speaker" }
        return "Speaker \(index + 1)"
    }

    public func speakerName(for speakerID: String?) -> String? {
        guard let speakerID else { return nil }
        let typed = (speakerNames[speakerID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultSpeakerName(for: speakerID) : typed
    }
}

/// Plain-text and Markdown layouts shared by Copy, the exports and the Word writer.
public enum FileTranscriptExporter {
    /// Transcript timestamp, such as "00:01:34".
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return "\(pad(total / 3600)):\(pad((total / 60) % 60)):\(pad(total % 60))"
    }

    /// For example: "Interview.mp3 · 28:13 · Parakeet · Sep 27, 2026".
    public static func detailsLine(for document: FileTranscriptDocument, dateText: String) -> String {
        var parts = [document.sourceFileName]
        if document.duration > 0 { parts.append(SubtitleBuilder.clock(document.duration)) }
        parts.append(document.engineName)
        parts.append(dateText)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// For example: "[00:01:34] Anne Janowitz", or "[00:01:34]" without speakers. Empty when the
    /// engine gave no timings and there are no speakers.
    public static func heading(for block: TranscriptBlock, in document: FileTranscriptDocument) -> String {
        var parts: [String] = []
        if document.hasTimings { parts.append("[\(timestamp(block.start))]") }
        if let name = document.speakerName(for: block.speakerID) { parts.append(name) }
        return parts.joined(separator: " ")
    }

    public static func plainText(_ document: FileTranscriptDocument, dateText: String) -> String {
        var lines = [document.displayTitle, detailsLine(for: document, dateText: dateText), ""]
        for block in document.blocks {
            let line = heading(for: block, in: document)
            if !line.isEmpty { lines.append(line) }
            lines.append(block.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func markdown(_ document: FileTranscriptDocument, dateText: String) -> String {
        var lines = ["# \(document.displayTitle)", "", "*\(detailsLine(for: document, dateText: dateText))*", ""]
        for block in document.blocks {
            let line = heading(for: block, in: document)
            if !line.isEmpty {
                lines.append("**\(line)**")
                lines.append("")
            }
            lines.append(block.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A safe file name (without extension) based on the title.
    public static func suggestedFileName(for document: FileTranscriptDocument) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = document.displayTitle.unicodeScalars
            .map { unsafe.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let limited = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "Transcript" : limited
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}

/// The result of turning an engine's output into a finished transcript.
public struct FileTranscriptComposition: Equatable, Sendable {
    public let blocks: [TranscriptBlock]
    public let hasTimings: Bool
    public let subtitleSRT: String

    public init(blocks: [TranscriptBlock], hasTimings: Bool, subtitleSRT: String) {
        self.blocks = blocks
        self.hasTimings = hasTimings
        self.subtitleSRT = subtitleSRT
    }
}

public enum FileTranscriptComposer {
    /// Builds paragraphs (with speakers when turns are given), applies the user's Text cleanup
    /// switches to each paragraph and subtitle, and formats the subtitles.
    public static func compose(
        text: String,
        pieces: [TimedTextPiece],
        speakerTurns: [SpeakerTurn],
        cleanup: TranscriptTextCleanupSettings
    ) -> FileTranscriptComposition {
        let built = TranscriptBlockBuilder.blocks(from: pieces, speakerTurns: speakerTurns)
        let hasTimings = !built.isEmpty
        let rawBlocks = hasTimings
            ? built
            : [TranscriptBlock(start: 0, end: 0, speakerID: nil, text: TranscriptBlockBuilder.collapsedWhitespace(text))]
        let blocks = rawBlocks.compactMap { block -> TranscriptBlock? in
            var cleaned = block
            cleaned.text = cleanedText(block.text, settings: cleanup)
            return cleaned.text.isEmpty ? nil : cleaned
        }
        var cues: [SubtitleCue] = []
        for cue in SubtitleBuilder.cues(from: pieces) {
            let cleaned = cleanedText(cue.text, settings: cleanup)
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(index: cues.count + 1, start: cue.start, end: cue.end, text: cleaned))
        }
        return FileTranscriptComposition(
            blocks: blocks,
            hasTimings: hasTimings,
            subtitleSRT: cues.isEmpty ? "" : SubtitleBuilder.srt(from: cues)
        )
    }

    /// Uses the Transcribe File tab's own switches (never the dictation settings). Fillers are
    /// removed before false starts, so "with uh with" becomes "with", not "with with". Numbers use
    /// the transcript style in `FileTranscriptNumberStyle`. Sentence capitals are restored after
    /// cleanup. Apple Intelligence polish runs separately, paragraph by paragraph.
    public static func cleanedText(_ text: String, settings: TranscriptTextCleanupSettings) -> String {
        var cleaned = text
        if settings.removeFillerWords {
            cleaned = removingStandaloneFillers(from: cleaned)
            cleaned = TranscriptTextCleanupPolicy.apply(cleaned, settings: TranscriptTextCleanupSettings(removeFillerWords: true))
        }
        if settings.removeFalseStarts {
            // Repeat so chains such as "in in in in" collapse fully.
            for _ in 0..<3 {
                let next = TranscriptTextCleanupPolicy.apply(cleaned, settings: TranscriptTextCleanupSettings(removeFalseStarts: true))
                if next == cleaned { break }
                cleaned = next
            }
        }
        if settings.convertSpokenNumbersToDigits {
            cleaned = FileTranscriptNumberStyle.apply(cleaned)
        }
        cleaned = TranscriptBlockBuilder.collapsedWhitespace(cleaned)
        guard settings.removeFillerWords || settings.removeFalseStarts || settings.convertSpokenNumbersToDigits else {
            return cleaned
        }
        cleaned = capitalizingSentenceStarts(cleaned)
        // "Um, in 1789…" becomes "In 1789…", not "in 1789…".
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = cleaned.first, first.isLowercase, original.first?.isUppercase == true,
           !original.hasPrefix(String(first)) {
            cleaned = first.uppercased() + cleaned.dropFirst()
        }
        return cleaned
    }

    /// "…the period. how do you…" becomes "…the period. How do you…". A trailing-off ellipsis
    /// ("the idea that... members") is left alone.
    static func capitalizingSentenceStarts(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![.…])[.?!]\s+([a-z])"#) else { return text }
        let result = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let letterRange = match.range(at: 1)
            result.replaceCharacters(in: letterRange, with: result.substring(with: letterRange).uppercased())
        }
        return result as String
    }

    /// Removes a filler that is a sentence of its own ("…nine. Uh. So…"), together with its
    /// punctuation, which the dictation rules would otherwise leave behind as "nine.. So".
    static func removingStandaloneFillers(from text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(^[ \t]*|[.!?…][ \t]+)(?:um+|uh+)[.!?,]*(?=\s|$)"#
        ) else { return text }
        var result = text
        for _ in 0..<3 {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let next = expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            if next == result { break }
            result = next
        }
        return result
    }
}

/// Decides whether an Apple Intelligence edit of one paragraph is safe to use. The edit is
/// accepted only when it keeps nearly every word: at most one word in ten (and at least two)
/// may be added, removed or changed. Anything bigger keeps the paragraph as transcribed.
public enum FileTranscriptPolishPolicy {
    public static func acceptedText(_ candidate: String, original: String) -> String? {
        var text = candidate
            .replacingOccurrences(of: "<transcript>", with: "")
            .replacingOccurrences(of: "</transcript>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”"]
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, let last = text.last, text.count > 1, quotes.contains(first), quotes.contains(last),
           !quotes.contains(trimmedOriginal.first ?? " ") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        let before = words(in: original)
        let after = words(in: text)
        guard !before.isEmpty else { return nil }
        let allowed = max(2, before.count / 10)
        guard wordDistance(before, after, limit: allowed) <= allowed else { return nil }
        return TranscriptBlockBuilder.collapsedWhitespace(text)
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Word-level edit distance. Stops early (returning limit + 1) once it must exceed `limit`.
    static func wordDistance(_ first: [String], _ second: [String], limit: Int) -> Int {
        if abs(first.count - second.count) > limit { return limit + 1 }
        var previous = Array(0...second.count)
        for (row, word) in first.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: second.count)
            var rowMinimum = current[0]
            for column in 1...max(second.count, 1) where column <= second.count {
                let cost = word == second[column - 1] ? 0 : 1
                current[column] = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
                rowMinimum = min(rowMinimum, current[column])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[second.count]
    }
}

/// Transcript-style numbers for long recordings: years ("seventeen eighty nine" → 1789), decades
/// ("the eighteen thirties" → 1830s), regnal names ("Louis the Sixteenth" → Louis XVI) and numbers
/// of 10 or more become digits. One to nine and "first" to "ninth" stay as words, as most style
/// guides do for prose, so "one of the" and "the first time" are left alone.
public enum FileTranscriptNumberStyle {
    private struct Token {
        let word: String
        let lowercased: String
        let range: NSRange
    }

    private static let digits: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let pluralTens: [String: Int] = [
        "tens": 10, "twenties": 20, "thirties": 30, "forties": 40, "fifties": 50,
        "sixties": 60, "seventies": 70, "eighties": 80, "nineties": 90
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60,
        "seventieth": 70, "eightieth": 80, "ninetieth": 90
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    public static func apply(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "[A-Za-z]+") else { return text }
        let source = text as NSString
        let tokens = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match -> Token in
            let word = source.substring(with: match.range)
            return Token(word: word, lowercased: word.lowercased(), range: match.range)
        }
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < tokens.count {
            if let regnal = regnalReplacement(tokens, at: index, source: source) {
                replacements.append(regnal.replacement)
                index += regnal.consumed
                continue
            }
            let run = runLength(tokens, from: index, source: source)
            var numberWords = 0
            while numberWords < run, isNumberWord(tokens[index + numberWords].lowercased) { numberWords += 1 }
            guard numberWords > 0 else {
                index += 1
                continue
            }
            // A number followed directly by another number it can't join ("eleven thirty",
            // "one two three") is ambiguous, so those words are left as they are.
            if let parsed = year(tokens, at: index, runLength: run) ?? cardinal(tokens, at: index, runLength: run),
               !(parsed.consumed < run && isNumberWord(tokens[index + parsed.consumed].lowercased)) {
                let first = tokens[index].range
                let last = tokens[index + parsed.consumed - 1].range
                let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                replacements.append((range, parsed.text))
                index += parsed.consumed
            } else {
                index += numberWords
            }
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in replacements.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }

    private static func isNumberWord(_ word: String) -> Bool {
        digits[word] != nil || teens[word] != nil || tens[word] != nil || ordinals[word] != nil
            || pluralTens[word] != nil || scales[word] != nil || word == "hundred" || word == "hundreds"
    }

    /// How many tokens from `start` are joined only by spaces or hyphens.
    private static func runLength(_ tokens: [Token], from start: Int, source: NSString) -> Int {
        var length = 1
        while start + length < tokens.count {
            let previous = tokens[start + length - 1].range
            let next = tokens[start + length].range
            let gap = source.substring(with: NSRange(location: NSMaxRange(previous), length: next.location - NSMaxRange(previous)))
            guard !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "-" }) else { break }
            length += 1
        }
        return length
    }

    /// "seventeen eighty nine" → 1789, "nineteen oh five" → 1905, "eighteen hundred" → 1800,
    /// "seventeen eighties" → 1780s. The first part must be 13–20 so times such as "eleven thirty"
    /// are not mistaken for years.
    private static func year(_ tokens: [Token], at start: Int, runLength: Int) -> (consumed: Int, text: String)? {
        guard runLength >= 2 else { return nil }
        let firstWord = tokens[start].lowercased
        guard let century = teens[firstWord] ?? (firstWord == "twenty" ? 20 : nil), century >= 13 else { return nil }
        let second = tokens[start + 1].lowercased
        let third = runLength >= 3 ? tokens[start + 2].lowercased : nil
        if second == "hundred" { return (2, "\(century)00") }
        if second == "hundreds" { return (2, "\(century)00s") }
        if second == "oh", let third, let digit = digits[third] { return (3, "\(century)0\(digit)") }
        if let teen = teens[second] { return (2, "\(century)\(teen)") }
        if let decade = pluralTens[second], decade >= 20 { return (2, "\(century)\(decade)s") }
        if let ten = tens[second] {
            if let third, let digit = digits[third] { return (3, "\(century)\(ten + digit)") }
            return (2, "\(century)\(ten)")
        }
        return nil
    }

    /// Whole numbers such as "forty" → 40, "six hundred thousand" → 600,000 and ordinals such as
    /// "nineteenth" → 19th. Returns nil (leave the words) for values under 10.
    private static func cardinal(_ tokens: [Token], at start: Int, runLength: Int) -> (consumed: Int, text: String)? {
        enum Previous { case start, digit, teen, tens, hundred, scale, and }
        var total = 0
        var current = 0
        var previous = Previous.start
        var consumed = 0
        var lastNumberConsumed = 0
        var isOrdinal = false
        while consumed < runLength {
            let word = tokens[start + consumed].lowercased
            if let value = ordinals[word] {
                let fits: Bool
                switch previous {
                case .start, .hundred, .scale, .and: fits = true
                case .tens: fits = value < 10
                case .digit, .teen: fits = false
                }
                guard fits else { break }
                current += value
                consumed += 1
                lastNumberConsumed = consumed
                isOrdinal = true
                break
            }
            if let value = digits[word] {
                guard previous == .start || previous == .tens || previous == .hundred || previous == .scale || previous == .and else { break }
                current += value
                previous = .digit
            } else if let value = teens[word] {
                guard previous == .start || previous == .hundred || previous == .scale || previous == .and else { break }
                current += value
                previous = .teen
            } else if let value = tens[word] {
                guard previous == .start || previous == .hundred || previous == .scale || previous == .and else { break }
                current += value
                previous = .tens
            } else if word == "hundred" {
                guard previous == .digit || previous == .teen, current < 100 else { break }
                current *= 100
                previous = .hundred
            } else if let scale = scales[word] {
                guard previous == .digit || previous == .teen || previous == .tens || previous == .hundred else { break }
                total += current * scale
                current = 0
                previous = .scale
            } else if word == "and" {
                guard previous == .hundred || previous == .scale,
                      consumed + 1 < runLength,
                      digits[tokens[start + consumed + 1].lowercased] != nil
                        || teens[tokens[start + consumed + 1].lowercased] != nil
                        || tens[tokens[start + consumed + 1].lowercased] != nil else { break }
                previous = .and
                consumed += 1
                continue
            } else {
                break
            }
            consumed += 1
            lastNumberConsumed = consumed
        }
        guard lastNumberConsumed > 0 else { return nil }
        let value = total + current
        guard value >= 10 else { return nil }
        let text = isOrdinal ? "\(value)\(ordinalSuffix(value))" : grouped(value)
        return (lastNumberConsumed, text)
    }

    /// Capitalized words that start sentences or phrases rather than names, so "In the First World
    /// War" is left alone.
    private static let notNames: Set<String> = [
        "a", "after", "and", "as", "at", "before", "but", "by", "during", "for", "from", "in", "into",
        "is", "it", "of", "on", "since", "so", "that", "then", "this", "to", "until", "was", "what",
        "when", "with"
    ]

    /// "Louis the Sixteenth" → "Louis XVI": a capitalized name, "the", then a capitalized ordinal
    /// that isn't followed by another capitalized word (as in "the Second Empire").
    private static func regnalReplacement(
        _ tokens: [Token],
        at start: Int,
        source: NSString
    ) -> (consumed: Int, replacement: (NSRange, String))? {
        guard start + 2 < tokens.count,
              tokens[start].word.first?.isUppercase == true,
              !notNames.contains(tokens[start].lowercased),
              tokens[start + 1].lowercased == "the",
              tokens[start + 2].word.first?.isUppercase == true,
              runLength(tokens, from: start, source: source) >= 3,
              source.substring(with: NSRange(
                  location: NSMaxRange(tokens[start].range),
                  length: tokens[start + 1].range.location - NSMaxRange(tokens[start].range)
              )) == " " else { return nil }
        var value = 0
        var consumed = 2
        let ordinalWord = tokens[start + 2].lowercased
        if let tensValue = tens[ordinalWord], start + 3 < tokens.count,
           let unit = ordinals[tokens[start + 3].lowercased], unit < 10,
           tokens[start + 3].word.first?.isUppercase == true,
           runLength(tokens, from: start, source: source) >= 4 {
            value = tensValue + unit
            consumed = 4
        } else if let ordinal = ordinals[ordinalWord] {
            value = ordinal
            consumed = 3
        } else {
            return nil
        }
        if start + consumed < tokens.count,
           tokens[start + consumed].word.first?.isUppercase == true,
           runLength(tokens, from: start, source: source) > consumed {
            return nil
        }
        let first = tokens[start + 1].range
        let last = tokens[start + consumed - 1].range
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return (consumed, (range, roman(value)))
    }

    private static func roman(_ value: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// 4-digit numbers stay plain (1500); 10,000 and up get thousands separators.
    private static func grouped(_ value: Int) -> String {
        let plain = String(value)
        guard value >= 10_000 else { return plain }
        var result = ""
        for (offset, character) in plain.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

/// Keeps finished file transcripts as one JSON file each, next to EchoFlow's transcript history.
/// Follows the same history switch and retention as dictation transcripts.
public struct FileTranscriptStore: Sendable {
    public static let storageDirectoryName = "EchoFlowFileTranscripts"

    public let directoryURL: URL

    public init(applicationSupportDirectory: URL) {
        self.directoryURL = applicationSupportDirectory.appendingPathComponent(Self.storageDirectoryName, isDirectory: true)
    }

    public static func standard() -> FileTranscriptStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return FileTranscriptStore(applicationSupportDirectory: support)
    }

    public func save(_ document: FileTranscriptDocument) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL(for: document.id), options: .atomic)
    }

    /// Newest first. Files that can't be read are skipped.
    public func documents() -> [FileTranscriptDocument] {
        let decoder = JSONDecoder()
        return ownedFiles().compactMap { url -> FileTranscriptDocument? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(FileTranscriptDocument.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Removes only this store's transcript files, never other files in the folder.
    public func deleteAll() throws {
        for url in ownedFiles() {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes transcripts older than the retention window and returns how many were removed.
    @discardableResult
    public func prune(retention: TranscriptHistoryRetention, now: Date = Date()) throws -> Int {
        guard let days = retention.retentionDays else { return 0 }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
        var removed = 0
        for document in documents() where document.createdAt < cutoff {
            try delete(id: document.id)
            removed += 1
        }
        return removed
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func ownedFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
    }
}
