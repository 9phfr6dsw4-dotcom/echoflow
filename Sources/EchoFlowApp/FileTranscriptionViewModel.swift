import AppKit
import EchoFlowCore
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class FileTranscriptionViewModel {
    enum Phase: Equatable {
        case idle
        case preparingAudio(fileName: String)
        case transcribing(fileName: String)
        case finished(fileName: String)
        case failed(String)
    }

    enum FileTranscriptionError: LocalizedError {
        case modelNotInstalled

        var errorDescription: String? {
            switch self {
            case .modelNotInstalled:
                return "The selected speech model isn't installed. Download it in the Speech Models tab, then try again."
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// nil while progress is unknown (the bar is shown as indeterminate).
    private(set) var progressFraction: Double?
    private(set) var audioDuration: TimeInterval = 0
    private(set) var transcript = ""
    private(set) var subtitleCues: [SubtitleCue] = []
    private(set) var saveError: String?
    @ObservationIgnored private var sourceBaseName = "Transcript"
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .preparingAudio, .transcribing: return true
        case .idle, .finished, .failed: return false
        }
    }

    var canExportSubtitles: Bool { !subtitleCues.isEmpty }

    var progressText: String {
        switch phase {
        case .preparingAudio:
            return "Preparing audio…"
        case .transcribing:
            if let progressFraction, audioDuration > 0 {
                return SubtitleBuilder.progressLabel(fraction: progressFraction, duration: audioDuration)
            }
            return "Transcribing…"
        case .idle, .finished, .failed:
            return ""
        }
    }

    func start(fileURL: URL, runtime: EchoFlowRuntime) {
        guard !isBusy else { return }
        guard FileTranscriptionSupport.isSupported(fileURL) else {
            showError(FileTranscriptionSupport.unsupportedMessage(for: fileURL))
            return
        }
        guard !runtime.dictation.isRecording, !runtime.dictation.isTranscribing else {
            showError("Finish the current dictation, then try again.")
            return
        }
        guard let catalog = runtime.modelLibrary.catalog else {
            showError(runtime.modelLibrary.startupError ?? "The speech model catalog is unavailable.")
            return
        }
        let engineID = runtime.modelLibrary.selectedEngineID
        let backend = TranscriptionBackend.resolve(
            engineID: engineID,
            catalog: catalog,
            installedDownloadIDs: runtime.modelLibrary.installedDownloadIDs
        )
        let modelDirectory = runtime.modelLibrary.installedModelDirectory(for: engineID)
        let languageIdentifier = runtime.preferredTranscriptionLanguageIdentifier
        let vocabularyTerms = TranscriptionVocabulary.terms(
            customTerms: runtime.customVocabulary.store.terms.map(\.term),
            learnedTerms: runtime.localLearning.store.learnedTerms
        )
        let fileName = fileURL.lastPathComponent
        sourceBaseName = fileURL.deletingPathExtension().lastPathComponent
        transcript = ""
        subtitleCues = []
        saveError = nil
        progressFraction = nil
        audioDuration = 0
        phase = .preparingAudio(fileName: fileName)
        task = Task { [weak self] in
            await self?.run(
                fileURL: fileURL,
                fileName: fileName,
                backend: backend,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                vocabularyTerms: vocabularyTerms
            )
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        progressFraction = nil
    }

    func showError(_ message: String) {
        phase = .failed(message)
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func save(asSubtitles: Bool) {
        saveError = nil
        let contents = asSubtitles ? SubtitleBuilder.srt(from: subtitleCues) : transcript + "\n"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asSubtitles ? (UTType(filenameExtension: "srt") ?? .plainText) : .plainText]
        panel.nameFieldStringValue = sourceBaseName + (asSubtitles ? ".srt" : ".txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveError = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    private func run(
        fileURL: URL,
        fileName: String,
        backend: TranscriptionBackend,
        modelDirectory: URL?,
        languageIdentifier: String,
        vocabularyTerms: [String]
    ) async {
        let isAccessingSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
        }
        var extractedURL: URL?
        defer {
            if let extractedURL { try? FileManager.default.removeItem(at: extractedURL) }
        }
        do {
            let extracted = try await AudioFileExtractor.extractAudio(from: fileURL)
            extractedURL = extracted.url
            try Task.checkCancellation()
            audioDuration = extracted.duration
            phase = .transcribing(fileName: fileName)

            let result: TimedFileTranscript
            switch backend {
            case .appleSpeech:
                result = try await AppleSpeechFileTranscriber.transcribe(
                    audioURL: extracted.url,
                    duration: extracted.duration,
                    localeIdentifier: languageIdentifier,
                    contextualPhrases: vocabularyTerms,
                    onProgress: { fraction in
                        Task { @MainActor in self.progressFraction = fraction }
                    }
                )
            case .parakeetV3, .whisperLargeV3Turbo:
                guard let modelDirectory else { throw FileTranscriptionError.modelNotInstalled }
                result = try await LocalModelTranscriber.transcribeFile(
                    backend: backend,
                    audioURL: extracted.url,
                    modelDirectory: modelDirectory,
                    languageIdentifier: languageIdentifier,
                    vocabularyTerms: vocabularyTerms,
                    onProgress: { fraction in
                        Task { @MainActor in self.progressFraction = fraction }
                    }
                )
            case .unavailable:
                throw FileTranscriptionError.modelNotInstalled
            }
            try Task.checkCancellation()
            transcript = result.text
            subtitleCues = SubtitleBuilder.cues(from: result.pieces)
            phase = .finished(fileName: fileName)
        } catch is CancellationError {
            // cancel() already reset the screen.
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
