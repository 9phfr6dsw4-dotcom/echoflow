import AVFoundation
import Foundation
import Speech

public struct AppleSpeechTranscriber: Sendable {
    public enum TranscriptionError: LocalizedError, Equatable {
        case unavailable
        case unsupportedLocale(String)
        case assetsNotInstalled(String)
        case emptyAudioFile

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Speech transcription is unavailable on this Mac."
            case .unsupportedLocale(let locale):
                return "Apple Speech does not support the locale \(locale)."
            case .assetsNotInstalled(let locale):
                return "Apple Speech assets for \(locale) are not ready yet. macOS may continue preparing them in the background; EchoFlow rechecks before the next dictation. You can also retry from the Dictation panel."
            case .emptyAudioFile:
                return "The recording is empty. Try speaking for a little longer."
            }
        }
    }

    public init() {}

    /// Installs system-managed assets if needed, then confirms that they are present.
    public func prepare(localeIdentifier: String) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(localeIdentifier)
        }

        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard try await installedLocaleIdentifier(localeIdentifier: locale.identifier) != nil else {
            throw TranscriptionError.assetsNotInstalled(locale.identifier)
        }
        return locale.identifier
    }

    /// Checks system-managed Speech asset availability without requesting or downloading anything.
    public func installedLocaleIdentifier(localeIdentifier: String) async throws -> String? {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(localeIdentifier)
        }
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else { return nil }
        return locale.identifier
    }

    /// Transcribes a local audio file. This method does not request or download assets.
    public func transcribe(
        audioFileAt url: URL,
        localeIdentifier: String,
        contextualPhrases: [String] = []
    ) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(localeIdentifier)
        }

        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw TranscriptionError.emptyAudioFile
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let context = Self.analysisContext(for: contextualPhrases) {
            try await analyzer.setContext(context)
        }
        let resultsTask = Task.detached(priority: .userInitiated) {
            var transcript = LiveTranscriptText()
            for try await result in transcriber.results {
                transcript.consume(text: String(result.text.characters), isFinal: result.isFinal)
            }
            return transcript.finalizedText
        }

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                throw TranscriptionError.emptyAudioFile
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
            return try await resultsTask.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw error
        }
    }

    public static func analysisContext(for phrases: [String]) -> AnalysisContext? {
        let boundedPhrases = Array(phrases.prefix(TranscriptionVocabulary.applePhraseLimit))
        guard !boundedPhrases.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = boundedPhrases
        return context
    }
}
