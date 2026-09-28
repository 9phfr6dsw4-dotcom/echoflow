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
        case detectingSpeakers(fileName: String)
        case failed(String)
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case text
        case markdown
        case word
        case subtitles

        var id: String { rawValue }

        var menuTitle: String {
            switch self {
            case .text: "Text (.txt)…"
            case .markdown: "Markdown (.md)…"
            case .word: "Word (.docx)…"
            case .subtitles: "Subtitles (.srt)…"
            }
        }

        var fileExtension: String {
            switch self {
            case .text: "txt"
            case .markdown: "md"
            case .word: "docx"
            case .subtitles: "srt"
            }
        }

        var contentType: UTType {
            switch self {
            case .text: .plainText
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .word: UTType(filenameExtension: "docx") ?? .data
            case .subtitles: UTType(filenameExtension: "srt") ?? .plainText
            }
        }
    }

    enum FileTranscriptionError: LocalizedError {
        case modelNotInstalled(String)

        var errorDescription: String? {
            switch self {
            case .modelNotInstalled(let name):
                return "\(name) isn't downloaded yet. Download it in the Speech Models tab, or choose another engine here."
            }
        }
    }

    static let engineDefaultsKey = "EchoFlow.fileTranscriptionEngineID"
    static let detectSpeakersDefaultsKey = "EchoFlow.fileTranscriptionDetectSpeakers"
    static let speakerCountDefaultsKey = "EchoFlow.fileTranscriptionSpeakerCount"
    static let whisperEngineID = "whisper-large-v3-turbo"

    private(set) var phase: Phase = .idle
    /// nil while progress is unknown (the bar is shown as indeterminate).
    private(set) var progressFraction: Double?
    private(set) var audioDuration: TimeInterval = 0
    private(set) var runningEngineName = ""
    private(set) var runningEngineIsWhisper = false
    /// The transcript on screen, just finished or reopened from Recent files.
    private(set) var document: FileTranscriptDocument?
    private(set) var recentDocuments: [FileTranscriptDocument] = []
    private(set) var historyEnabled = true
    private(set) var retention: TranscriptHistoryRetention = .thirtyDays
    private(set) var saveError: String?

    /// The Title box. It edits the transcript on screen; before a transcript exists it is the
    /// title for the next one.
    var title = "" {
        didSet { titleDidChange() }
    }
    var engineID: String {
        didSet { UserDefaults.standard.set(engineID, forKey: Self.engineDefaultsKey) }
    }
    var detectSpeakers: Bool {
        didSet { UserDefaults.standard.set(detectSpeakers, forKey: Self.detectSpeakersDefaultsKey) }
    }
    /// 0 means "detect automatically".
    var speakerCount: Int {
        didSet { UserDefaults.standard.set(speakerCount, forKey: Self.speakerCountDefaultsKey) }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private let store = FileTranscriptStore.standard()

    init() {
        let defaults = UserDefaults.standard
        engineID = defaults.string(forKey: Self.engineDefaultsKey) ?? ModelSelection.parakeetEngineID
        detectSpeakers = defaults.bool(forKey: Self.detectSpeakersDefaultsKey)
        speakerCount = defaults.integer(forKey: Self.speakerCountDefaultsKey)
    }

    var isBusy: Bool {
        switch phase {
        case .preparingAudio, .transcribing, .detectingSpeakers: return true
        case .idle, .failed: return false
        }
    }

    var progressText: String {
        switch phase {
        case .preparingAudio:
            return "Preparing audio…"
        case .transcribing:
            if let progressFraction, audioDuration > 0 {
                return SubtitleBuilder.progressLabel(fraction: progressFraction, duration: audioDuration)
            }
            return "Transcribing…"
        case .detectingSpeakers:
            if let progressFraction {
                return "Finding speakers… \(Int((progressFraction * 100).rounded()))%"
            }
            return "Getting speaker detection ready… (the first time, this downloads its model)"
        case .idle, .failed:
            return ""
        }
    }

    var busyFileName: String? {
        switch phase {
        case .preparingAudio(let fileName), .transcribing(let fileName), .detectingSpeakers(let fileName):
            return fileName
        case .idle, .failed:
            return nil
        }
    }

    /// Engines that can transcribe right now: Apple Speech, plus downloaded models.
    func availableEngines(runtime: EchoFlowRuntime) -> [ModelEngine] {
        let library = runtime.modelLibrary
        return (library.catalog?.engines ?? []).filter { library.isReady($0) }
    }

    /// Called when the tab appears: keeps the engine choice valid and reloads Recent files.
    func refresh(runtime: EchoFlowRuntime) {
        let available = availableEngines(runtime: runtime).map(\.id)
        if !available.isEmpty, !available.contains(engineID) {
            engineID = available.contains(ModelSelection.parakeetEngineID)
                ? ModelSelection.parakeetEngineID
                : (available.first ?? ModelSelection.appleSpeechEngineID)
        }
        historyEnabled = runtime.history.settings.historyEnabled
        retention = runtime.history.settings.retention
        reloadRecent()
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
        refresh(runtime: runtime)
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
        let cleanup = runtime.textCleanup.settings
        let engineName = Self.shortName(for: backend, fallback: catalog.engine(id: engineID)?.displayName ?? engineID)
        let wantsSpeakers = detectSpeakers
        let requestedSpeakers = speakerCount >= 2 ? speakerCount : nil
        let fileName = fileURL.lastPathComponent

        // A new file starts a new transcript; a title typed before any transcript is kept.
        if document != nil {
            document = nil
            title = ""
        }
        saveError = nil
        progressFraction = nil
        audioDuration = 0
        runningEngineName = engineName
        runningEngineIsWhisper = backend == .whisperLargeV3Turbo
        phase = .preparingAudio(fileName: fileName)
        let runID = UUID()
        self.runID = runID
        task = Task { [weak self] in
            await self?.run(
                runID: runID,
                fileURL: fileURL,
                fileName: fileName,
                backend: backend,
                engineName: engineName,
                modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier,
                vocabularyTerms: vocabularyTerms,
                cleanup: cleanup,
                detectSpeakers: wantsSpeakers,
                speakerCount: requestedSpeakers
            )
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runID = UUID()
        phase = .idle
        progressFraction = nil
    }

    func showError(_ message: String) {
        phase = .failed(message)
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    /// Empties the transcript area and the Title box. Saved transcripts stay in Recent files.
    func clear() {
        guard !isBusy else { return }
        document = nil
        title = ""
        saveError = nil
        phase = .idle
    }

    func open(_ saved: FileTranscriptDocument) {
        guard !isBusy else { return }
        document = saved
        title = saved.title
        saveError = nil
        phase = .idle
    }

    func delete(_ saved: FileTranscriptDocument) {
        do {
            try store.delete(id: saved.id)
        } catch {
            saveError = "Couldn't delete the transcript: \(error.localizedDescription)"
        }
        if document?.id == saved.id {
            document = nil
            title = ""
        }
        reloadRecent()
    }

    func speakerNameText(for speakerID: String) -> String {
        document?.speakerNames[speakerID] ?? ""
    }

    func rename(speakerID: String, to name: String) {
        guard var current = document else { return }
        if name.isEmpty {
            current.speakerNames.removeValue(forKey: speakerID)
        } else {
            current.speakerNames[speakerID] = name
        }
        guard current != document else { return }
        document = current
        persist(current)
    }

    func dateText(for saved: FileTranscriptDocument) -> String {
        saved.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    func detailsLine(for saved: FileTranscriptDocument) -> String {
        FileTranscriptExporter.detailsLine(for: saved, dateText: dateText(for: saved))
    }

    func copyTranscript() {
        guard let document else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            FileTranscriptExporter.plainText(document, dateText: dateText(for: document)),
            forType: .string
        )
    }

    func export(_ format: ExportFormat) {
        guard let document else { return }
        saveError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = FileTranscriptExporter.suggestedFileName(for: document) + "." + format.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let dateText = dateText(for: document)
            let data: Data
            switch format {
            case .text:
                data = Data(FileTranscriptExporter.plainText(document, dateText: dateText).utf8)
            case .markdown:
                data = Data(FileTranscriptExporter.markdown(document, dateText: dateText).utf8)
            case .word:
                data = try TranscriptWordExporter.data(for: document, dateText: dateText)
            case .subtitles:
                data = Data(document.subtitleSRT.utf8)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            saveError = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    private func titleDidChange() {
        guard var current = document, current.title != title else { return }
        current.title = title
        document = current
        persist(current)
    }

    private func persist(_ saved: FileTranscriptDocument) {
        guard historyEnabled else { return }
        do {
            try store.save(saved)
        } catch {
            saveError = "Couldn't keep this transcript in Recent files: \(error.localizedDescription)"
        }
        reloadRecent()
    }

    private func reloadRecent() {
        guard historyEnabled else {
            recentDocuments = []
            return
        }
        do {
            try store.prune(retention: retention)
        } catch {
            saveError = "Couldn't remove old transcripts: \(error.localizedDescription)"
        }
        recentDocuments = store.documents()
    }

    private func reportProgress(_ fraction: Double, runID: UUID, speakers: Bool) {
        guard self.runID == runID else { return }
        switch phase {
        case .transcribing where !speakers, .detectingSpeakers where speakers:
            progressFraction = fraction
        default:
            break
        }
    }

    private func run(
        runID: UUID,
        fileURL: URL,
        fileName: String,
        backend: TranscriptionBackend,
        engineName: String,
        modelDirectory: URL?,
        languageIdentifier: String,
        vocabularyTerms: [String],
        cleanup: TranscriptTextCleanupSettings,
        detectSpeakers: Bool,
        speakerCount: Int?
    ) async {
        let isAccessingSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
        }
        var extractedURL: URL?
        defer {
            if let extractedURL { try? FileManager.default.removeItem(at: extractedURL) }
        }
        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in self.reportProgress(fraction, runID: runID, speakers: false) }
        }
        let onSpeakerProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in self.reportProgress(fraction, runID: runID, speakers: true) }
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
                    onProgress: onProgress
                )
            case .parakeetV3, .whisperLargeV3Turbo:
                guard let modelDirectory else { throw FileTranscriptionError.modelNotInstalled(engineName) }
                result = try await LocalModelTranscriber.transcribeFile(
                    backend: backend,
                    audioURL: extracted.url,
                    modelDirectory: modelDirectory,
                    languageIdentifier: languageIdentifier,
                    vocabularyTerms: vocabularyTerms,
                    wordTimings: detectSpeakers,
                    onProgress: onProgress
                )
            case .unavailable:
                throw FileTranscriptionError.modelNotInstalled(engineName)
            }
            try Task.checkCancellation()

            var turns: [SpeakerTurn] = []
            if detectSpeakers {
                progressFraction = nil
                phase = .detectingSpeakers(fileName: fileName)
                turns = try await SpeakerDetector.speakerTurns(
                    audioURL: extracted.url,
                    speakerCount: speakerCount,
                    onProgress: onSpeakerProgress
                )
                try Task.checkCancellation()
            }

            let text = result.text
            let pieces = result.pieces
            let speakerTurns = turns
            let composition = await Task.detached(priority: .userInitiated) {
                FileTranscriptComposer.compose(text: text, pieces: pieces, speakerTurns: speakerTurns, cleanup: cleanup)
            }.value
            guard self.runID == runID, !Task.isCancelled else { return }

            let finished = FileTranscriptDocument(
                title: title,
                sourceFileName: fileName,
                duration: extracted.duration,
                engineName: engineName,
                hasTimings: composition.hasTimings,
                blocks: composition.blocks,
                subtitleSRT: composition.subtitleSRT
            )
            document = finished
            progressFraction = nil
            phase = .idle
            persist(finished)
        } catch is CancellationError {
            // cancel() already reset the screen.
        } catch {
            guard self.runID == runID, !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private static func shortName(for backend: TranscriptionBackend, fallback: String) -> String {
        switch backend {
        case .appleSpeech: "Apple Speech"
        case .parakeetV3: "Parakeet"
        case .whisperLargeV3Turbo: "Whisper"
        case .unavailable: fallback
        }
    }
}
