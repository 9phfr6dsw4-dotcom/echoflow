import Foundation

/// File types the Transcribe File tab accepts. Checking the extension first gives the user a clear
/// message instead of a decoding failure.
public enum FileTranscriptionSupport {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func isSupported(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return audioExtensions.contains(fileExtension) || videoExtensions.contains(fileExtension)
    }

    public static func unsupportedMessage(for url: URL) -> String {
        "EchoFlow can't transcribe \"\(url.lastPathComponent)\". Supported files: MP3, WAV, M4A, AAC, FLAC, AIFF, CAF, MP4, MOV, and M4V."
    }
}

/// A piece of transcript with its position in the audio, such as a Parakeet token, a Whisper
/// segment, or an Apple Speech word. A new word begins where there is whitespace between pieces.
public struct TimedTextPiece: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct SubtitleCue: Equatable, Sendable {
    public let index: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(index: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Turns timed transcript pieces into subtitle cues and SRT text.
public enum SubtitleBuilder {
    public static let maximumCueDuration: TimeInterval = 6
    public static let maximumCueCharacters = 84
    public static let pauseThreshold: TimeInterval = 1
    public static let minimumSentenceCueDuration: TimeInterval = 1.5

    /// Groups pieces into cues. A cue ends after a sentence (once it is at least 1.5 seconds long),
    /// at a pause longer than 1 second, or before it would pass 6 seconds or 84 characters.
    /// Cues only break where a new word starts, so words are never split.
    public static func cues(from pieces: [TimedTextPiece]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var text = ""
        var cueStart: TimeInterval?
        var cueEnd: TimeInterval = 0

        func flush() {
            let cleaned = collapsedWhitespace(text)
            if let start = cueStart, !cleaned.isEmpty {
                let safeStart = max(start, cues.last?.end ?? 0)
                let safeEnd = cueEnd > safeStart ? cueEnd : safeStart + 0.5
                cues.append(SubtitleCue(index: cues.count + 1, start: safeStart, end: safeEnd, text: cleaned))
            }
            text = ""
            cueStart = nil
        }

        for piece in pieces where !piece.text.isEmpty {
            let startsWord = (piece.text.first?.isWhitespace ?? false) || (text.last?.isWhitespace ?? false)
            if let start = cueStart, startsWord {
                let tooLong = piece.end - start > maximumCueDuration
                    || text.count + piece.text.count > maximumCueCharacters
                let paused = piece.start - cueEnd > pauseThreshold
                if tooLong || paused { flush() }
            }
            if cueStart == nil { cueStart = piece.start }
            text += piece.text
            cueEnd = max(cueEnd, piece.end)
            if let start = cueStart, endsSentence(text), cueEnd - start >= minimumSentenceCueDuration {
                flush()
            }
        }
        flush()
        return cues
    }

    public static func srt(from cues: [SubtitleCue]) -> String {
        cues.map { cue in
            "\(cue.index)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// SRT time format: HH:MM:SS,mmm
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let wholeSeconds = (totalMilliseconds / 1000) % 60
        let milliseconds = totalMilliseconds % 1000
        return "\(pad(hours, 2)):\(pad(minutes, 2)):\(pad(wholeSeconds, 2)),\(pad(milliseconds, 3))"
    }

    /// Short clock for progress text, such as "3:42" or "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let wholeSeconds = total % 60
        return hours > 0
            ? "\(hours):\(pad(minutes, 2)):\(pad(wholeSeconds, 2))"
            : "\(minutes):\(pad(wholeSeconds, 2))"
    }

    /// For example: "Transcribing… 3:42 / 58:00".
    public static func progressLabel(fraction: Double, duration: TimeInterval) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "Transcribing… \(clock(clamped * duration)) / \(clock(duration))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return ".?!…".contains(last)
    }
}
