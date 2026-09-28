import EchoFlowCore
import FluidAudio
import Foundation
import WhisperKit

// WhisperKit owns mutable decoding state. Its only consumer is the serialized cache operation.
private final class CachedWhisperSession: @unchecked Sendable {
    let whisper: WhisperKit
    let tokenizer: TokenizerWrapper

    init(whisper: WhisperKit, tokenizer: TokenizerWrapper) {
        self.whisper = whisper
        self.tokenizer = tokenizer
    }
}

struct LocalModelTranscriber {
    private static let whisperCache = SerializedModelCache<CachedWhisperSession>()
    enum TranscriptionError: LocalizedError {
        case unavailableBackend(String)
        case missingLocalAsset(String)
        case unsupportedParakeetLanguage(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unavailableBackend(let engineID):
                return "The selected transcription engine is not installed or supported: \(engineID)."
            case .missingLocalAsset(let path):
                return "A required local model file is missing: \(path). Reinstall the model from EchoFlow."
            case .unsupportedParakeetLanguage(let language):
                return "Parakeet v3 does not support the selected language (\(language)). Choose one of its 25 listed languages or use Whisper/Apple Speech."
            case .emptyTranscript:
                return "No speech was recognized. Try again or check the microphone input."
            }
        }
    }

    static func transcribe(
        backend: TranscriptionBackend,
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        vocabularyTerms: [String] = [],
        ctcVocabularyDirectory: URL? = nil
    ) async throws -> String {
        switch backend {
        case .parakeetV3:
            return try await transcribeParakeet(
                audioURL: audioURL,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                vocabularyTerms: vocabularyTerms,
                ctcVocabularyDirectory: ctcVocabularyDirectory
            )
        case .whisperLargeV3Turbo:
            return try await transcribeWhisper(
                audioURL: audioURL,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                vocabularyTerms: vocabularyTerms
            )
        case .appleSpeech, .unavailable:
            throw TranscriptionError.unavailableBackend(String(describing: backend))
        }
    }

    private static func transcribeParakeet(
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        vocabularyTerms: [String],
        ctcVocabularyDirectory: URL?
    ) async throws -> String {
        let code = normalizedLanguageCode(languageIdentifier)
        let language: Language?
        if let code {
            guard let supported = Language(rawValue: code) else {
                throw TranscriptionError.unsupportedParakeetLanguage(languageIdentifier ?? code)
            }
            language = supported
        } else {
            language = nil
        }

        let models = try AsrModels.loadLocal(
            from: modelDirectory,
            version: .v3,
            encoderPrecision: .int8V2
        )
        let manager = AsrManager(config: .default, models: models)
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language
        )
        let baseTranscript = try nonempty(result.text)
        let tokenTimings = result.tokenTimings
        guard ParakeetVocabularyAvailability.canApplyCustomTerms(
            hasTerms: !vocabularyTerms.isEmpty,
            companionInstalled: ctcVocabularyDirectory != nil,
            hasTokenTimings: tokenTimings?.isEmpty == false
        ), let ctcVocabularyDirectory,
           let tokenTimings else {
            return baseTranscript
        }

        do {
            let ctcModels = try await CtcModels.loadDirect(
                from: ctcVocabularyDirectory,
                variant: .ctc06b
            )
            let vocabulary = CustomVocabularyContext(
                terms: vocabularyTerms.map { CustomVocabularyTerm(text: $0) }
            )
            let boosting = try await VocabularyBoostingSession(
                vocabulary: vocabulary,
                ctcModels: ctcModels
            )
            let audioSamples = try AudioConverter().resampleAudioFile(audioURL)
            let rescored = await boosting.rescore(
                text: result.text,
                tokenTimings: tokenTimings,
                audioSamples: audioSamples
            )
            let finalText = rescored?.wasModified == true ? (rescored?.text ?? result.text) : result.text
            return try nonempty(finalText)
        } catch {
            return baseTranscript
        }
    }

    private static func transcribeWhisper(
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        vocabularyTerms: [String]
    ) async throws -> String {
        try await whisperCache.withModel(at: modelDirectory, load: { directory in
            try await loadWhisperSession(from: directory)
        }, operation: { session in
            let promptText = TranscriptionVocabulary.whisperPromptText(from: vocabularyTerms)
            let promptTokens = promptText.isEmpty ? nil : session.tokenizer.encode(text: promptText)
            let options = DecodingOptions(
                language: normalizedLanguageCode(languageIdentifier),
                skipSpecialTokens: true,
                withoutTimestamps: true,
                promptTokens: promptTokens
            )
            let results = try await session.whisper.transcribe(
                audioPath: audioURL.path, decodeOptions: options
            )
            return try nonempty(results.map(\.text).joined(separator: " "))
        })
    }

    /// Loads Whisper into the shared cache before the first dictation. On a fresh install Core ML
    /// prepares the large model for this Mac the first time it loads, which can take several
    /// minutes; doing it here keeps that wait out of a dictation. Later calls return immediately
    /// while the loaded model is still cached.
    static func prepareWhisper(modelDirectory: URL) async throws {
        try await whisperCache.withModel(at: modelDirectory, load: { directory in
            try await loadWhisperSession(from: directory)
        }, operation: { _ in })
    }

    private static func loadWhisperSession(from directory: URL) async throws -> CachedWhisperSession {
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            throw TranscriptionError.missingLocalAsset(tokenizerURL.lastPathComponent)
        }
        let offlineHub = HubApiWrapper(
            downloadBase: directory,
            endpoint: "file:///EchoFlow-offline-hub"
        )
        let tokenizer = try await AutoTokenizerWrapper.from(
            modelFolder: directory,
            hubApi: offlineHub
        )
        guard tokenizer.convertTokenToId("<|endoftext|>") != nil else {
            throw TranscriptionError.missingLocalAsset("tokenizer.json (Whisper special tokens)")
        }
        let config = WhisperKitConfig(
            modelFolder: directory.path,
            tokenizerFolder: directory,
            verbose: false,
            prewarm: true,
            load: true,
            download: false,
            useBackgroundDownloadSession: false
        )
        return try await CachedWhisperSession(
            whisper: WhisperKit(config), tokenizer: tokenizer
        )
    }

    private static func normalizedLanguageCode(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let firstPart = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return firstPart.map(String.init)?.lowercased()
    }

    private static func nonempty(_ text: String) throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TranscriptionError.emptyTranscript }
        return cleaned
    }
}

/// Transcript of an imported file. `pieces` carries timings for subtitle export and is empty when
/// the engine doesn't provide them.
struct TimedFileTranscript: Sendable {
    let text: String
    let pieces: [TimedTextPiece]
}

extension LocalModelTranscriber {
    /// Transcribes an imported audio file with Parakeet or Whisper and keeps timings for .srt export.
    /// Parakeet handles long files with its built-in disk-backed chunking; Whisper uses VAD chunking.
    static func transcribeFile(
        backend: TranscriptionBackend,
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        vocabularyTerms: [String],
        wordTimings: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimedFileTranscript {
        switch backend {
        case .parakeetV3:
            return try await transcribeParakeetFile(
                audioURL: audioURL,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                onProgress: onProgress
            )
        case .whisperLargeV3Turbo:
            return try await transcribeWhisperFile(
                audioURL: audioURL,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                vocabularyTerms: vocabularyTerms,
                wordTimings: wordTimings,
                onProgress: onProgress
            )
        case .appleSpeech, .unavailable:
            throw TranscriptionError.unavailableBackend(String(describing: backend))
        }
    }

    private static func transcribeParakeetFile(
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimedFileTranscript {
        var language: Language?
        if let code = normalizedLanguageCode(languageIdentifier) {
            guard let supported = Language(rawValue: code) else {
                throw TranscriptionError.unsupportedParakeetLanguage(languageIdentifier ?? code)
            }
            language = supported
        }
        let models = try AsrModels.loadLocal(
            from: modelDirectory,
            version: .v3,
            encoderPrecision: .int8V2
        )
        let manager = AsrManager(config: .default, models: models)
        let progressStream = await manager.transcriptionProgressStream
        let progressTask = Task {
            do {
                for try await fraction in progressStream { onProgress(fraction) }
            } catch {}
        }
        defer { progressTask.cancel() }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language
        )
        let text = try nonempty(result.text)
        let pieces = (result.tokenTimings ?? []).map { timing in
            TimedTextPiece(text: timing.token, start: timing.startTime, end: timing.endTime)
        }
        return TimedFileTranscript(text: text, pieces: pieces)
    }

    private static func transcribeWhisperFile(
        audioURL: URL,
        modelDirectory: URL,
        languageIdentifier: String?,
        vocabularyTerms: [String],
        wordTimings: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimedFileTranscript {
        try await whisperCache.withModel(at: modelDirectory, load: { directory in
            try await loadWhisperSession(from: directory)
        }, operation: { session in
            let promptText = TranscriptionVocabulary.whisperPromptText(from: vocabularyTerms)
            let promptTokens = promptText.isEmpty ? nil : session.tokenizer.encode(text: promptText)
            let options = DecodingOptions(
                language: normalizedLanguageCode(languageIdentifier),
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: wordTimings,
                promptTokens: promptTokens,
                chunkingStrategy: .vad
            )
            let progressTask = Task {
                while !Task.isCancelled {
                    onProgress(session.whisper.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { progressTask.cancel() }
            let results = try await session.whisper.transcribe(
                audioPath: audioURL.path, decodeOptions: options
            )
            let text = try nonempty(results.map(\.text).joined(separator: " "))
            let segments = results.flatMap(\.segments)
            // Word timings (requested for speaker detection) let speaker changes fall between
            // words; otherwise each segment is one timed piece.
            let wordPieces: [TimedTextPiece] = wordTimings
                ? segments.flatMap { segment -> [TimedTextPiece] in
                    (segment.words ?? []).compactMap { word -> TimedTextPiece? in
                        let spoken = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !spoken.isEmpty else { return nil }
                        return TimedTextPiece(text: " " + spoken, start: TimeInterval(word.start), end: TimeInterval(word.end))
                    }
                }
                : []
            let pieces = !wordPieces.isEmpty ? wordPieces : segments.map { segment in
                TimedTextPiece(
                    text: " " + segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end)
                )
            }
            return TimedFileTranscript(text: text, pieces: pieces)
        })
    }
}
