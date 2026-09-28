import AVFoundation
import EchoFlowCore
import Foundation
import Speech

/// Transcribes an imported file with Apple's on-device speech models and keeps word timings for
/// subtitle export and progress. It uses SpeechTranscriber, Apple's newest model built for
/// long-form audio, when this Mac and language support it, downloading its system-managed assets
/// the first time if needed. Otherwise it falls back to DictationTranscriber, the model live
/// dictation uses, with its time-indexed long-form preset.
enum AppleSpeechFileTranscriber {
    enum AppleSpeechFileError: LocalizedError {
        case notReady(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .notReady(let locale):
                return "Apple Speech isn't ready for \(locale) yet. Choose Prepare Apple Speech in the Dictation panel, or pick Parakeet or Whisper in Speech Models, then try again."
            case .emptyTranscript:
                return "No speech was found in this file."
            }
        }
    }

    private struct CollectedResults: Sendable {
        var text = ""
        var pieces: [TimedTextPiece] = []
    }

    static func transcribe(
        audioURL: URL,
        duration: TimeInterval,
        localeIdentifier: String,
        contextualPhrases: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimedFileTranscript {
        let requestedLocale = Locale(identifier: localeIdentifier)

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let resultsTask = Task.detached(priority: .userInitiated) { () throws -> CollectedResults in
                var collected = CollectedResults()
                for try await result in transcriber.results {
                    collected.text += " " + String(result.text.characters)
                    collected.pieces += timedPieces(from: result.text, fallbackRange: result.range)
                    report(progressAt: result.range, duration: duration, onProgress: onProgress)
                }
                return collected
            }
            return try await finish(audioURL: audioURL, analyzer: analyzer, resultsTask: resultsTask)
        }

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechFileError.notReady(localeIdentifier)
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppleSpeechFileError.notReady(locale.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let context = AppleSpeechTranscriber.analysisContext(for: contextualPhrases) {
            try await analyzer.setContext(context)
        }
        let resultsTask = Task.detached(priority: .userInitiated) { () throws -> CollectedResults in
            var collected = CollectedResults()
            for try await result in transcriber.results {
                collected.text += " " + String(result.text.characters)
                collected.pieces += timedPieces(from: result.text, fallbackRange: result.range)
                report(progressAt: result.range, duration: duration, onProgress: onProgress)
            }
            return collected
        }
        return try await finish(audioURL: audioURL, analyzer: analyzer, resultsTask: resultsTask)
    }

    private static func finish(
        audioURL: URL,
        analyzer: SpeechAnalyzer,
        resultsTask: Task<CollectedResults, any Error>
    ) async throws -> TimedFileTranscript {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                throw AppleSpeechFileError.emptyTranscript
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw error
        }
        let collected = try await resultsTask.value
        let text = collected.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { throw AppleSpeechFileError.emptyTranscript }
        return TimedFileTranscript(text: text, pieces: collected.pieces)
    }

    private static func report(
        progressAt range: CMTimeRange,
        duration: TimeInterval,
        onProgress: @Sendable (Double) -> Void
    ) {
        let reached = range.end.seconds
        guard duration > 0, reached.isFinite else { return }
        onProgress(min(max(reached / duration, 0), 1))
    }

    /// Turns one result's attributed text into timed pieces. Text without a time code (such as
    /// spaces or punctuation) is attached to the neighboring timed word so nothing is lost, and
    /// each result starts a new word.
    private static func timedPieces(from text: AttributedString, fallbackRange: CMTimeRange) -> [TimedTextPiece] {
        var pieces: [TimedTextPiece] = []
        var pending = " "
        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                pending += runText
                continue
            }
            pieces.append(TimedTextPiece(
                text: pending + runText,
                start: timeRange.start.seconds,
                end: timeRange.end.seconds
            ))
            pending = ""
        }
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = pieces.popLast() {
                pieces.append(TimedTextPiece(text: last.text + pending, start: last.start, end: last.end))
            } else {
                pieces.append(TimedTextPiece(
                    text: pending,
                    start: fallbackRange.start.seconds,
                    end: fallbackRange.end.seconds
                ))
            }
        }
        return pieces
    }
}
