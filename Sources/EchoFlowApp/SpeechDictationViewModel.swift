import AVFoundation
import EchoFlowCore
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechDictationViewModel {
    private(set) var isPreparingAssets = false
    private(set) var isCheckingAssets = false
    private(set) var assetsPrepared = false
    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var microphoneName = "System default microphone"
    private(set) var transcript = ""
    var errorMessage: String?

    @ObservationIgnored private let transcriber = AppleSpeechTranscriber()
    @ObservationIgnored private let microphoneSettings: MicrophoneSettingsViewModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var preparedLocaleIdentifier: String?
    @ObservationIgnored private var assetStatusCheckTask: Task<Void, Never>?
    @ObservationIgnored private var assetStatusCheckTaskLocale: String?
    @ObservationIgnored private var assetInstallationTask: Task<Void, Never>?
    @ObservationIgnored private var assetInstallationTaskLocale: String?
    @ObservationIgnored private var recordingBackend: TranscriptionBackend?
    @ObservationIgnored private var recordingModelDirectory: URL?
    @ObservationIgnored private var recordingCtcVocabularyDirectory: URL?
    @ObservationIgnored private var recordingLanguageIdentifier: String?
    @ObservationIgnored private var recordingVocabularyTerms: [String] = []
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var audioWriter: AudioFileWriter?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var completedRecordingAudioData: Data?
    @ObservationIgnored private var inputBridge: AudioAnalyzerInputBridge?
    @ObservationIgnored private var speechAnalyzer: SpeechAnalyzer?
    @ObservationIgnored private var liveResultsTask: Task<Void, Never>?
    @ObservationIgnored private var liveTranscript = LiveTranscriptText()
    @ObservationIgnored private var tentativeTranscript = ParakeetTentativeTranscript()
    @ObservationIgnored private var previewToken: UUID?
    @ObservationIgnored private var previewAudio: ParakeetPreviewAudioQueue?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored var onChange: ((SpeechDictationViewModel) -> Void)?

    static let preparedSpeechLocaleDefaultsKey = "EchoFlow.preparedSpeechLocale"

    init(microphoneSettings: MicrophoneSettingsViewModel, defaults: UserDefaults = .standard) {
        self.microphoneSettings = microphoneSettings
        self.defaults = defaults
        preparedLocaleIdentifier = defaults.string(forKey: Self.preparedSpeechLocaleDefaultsKey)
        Self.removeInterruptedRecordings()
    }

    func isAppleSpeechPrepared(for localeIdentifier: String) -> Bool {
        assetsPrepared && PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: preparedLocaleIdentifier,
            requestedIdentifier: localeIdentifier,
            assetsInstalled: assetsPrepared
        )
    }

    func prepareAppleSpeech(localeIdentifier: String = Locale.current.identifier) async {
        await checkAppleSpeechAssets(localeIdentifier: localeIdentifier)
        guard !isAppleSpeechPrepared(for: localeIdentifier), !isPreparingAssets else { return }

        if let currentTask = assetInstallationTask {
            let currentLocale = assetInstallationTaskLocale
            await currentTask.value
            if currentLocale == localeIdentifier { return }
        }

        isPreparingAssets = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.installAppleSpeechAssets(localeIdentifier: localeIdentifier)
        }
        assetInstallationTaskLocale = localeIdentifier
        assetInstallationTask = task
        await task.value
    }

    private func installAppleSpeechAssets(localeIdentifier: String) async {
        defer {
            isPreparingAssets = false
            assetInstallationTask = nil
            assetInstallationTaskLocale = nil
        }
        do {
            let installedLocale = try await transcriber.prepare(localeIdentifier: localeIdentifier)
            guard PreparedSpeechLocalePolicy.isPrepared(
                preparedIdentifier: installedLocale,
                requestedIdentifier: localeIdentifier,
                assetsInstalled: true
            ) else {
                throw AppleSpeechTranscriber.TranscriptionError.assetsNotInstalled(localeIdentifier)
            }
            preparedLocaleIdentifier = installedLocale
            assetsPrepared = true
            defaults.set(installedLocale, forKey: Self.preparedSpeechLocaleDefaultsKey)
        } catch {
            preparedLocaleIdentifier = nil
            assetsPrepared = false
            defaults.removeObject(forKey: Self.preparedSpeechLocaleDefaultsKey)
            errorMessage = error.localizedDescription
        }
    }

    /// Checks whether Apple Speech assets are installed without initiating downloads.
    func checkAppleSpeechAssets(localeIdentifier: String) async {
        if let currentTask = assetInstallationTask {
            let currentLocale = assetInstallationTaskLocale
            await currentTask.value
            if currentLocale == localeIdentifier { return }
        }
        if let currentTask = assetStatusCheckTask {
            let currentLocale = assetStatusCheckTaskLocale
            await currentTask.value
            if currentLocale == localeIdentifier { return }
            await checkAppleSpeechAssets(localeIdentifier: localeIdentifier)
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkAppleSpeechAssetStatus(localeIdentifier: localeIdentifier)
        }
        assetStatusCheckTaskLocale = localeIdentifier
        assetStatusCheckTask = task
        await task.value
    }

    private func checkAppleSpeechAssetStatus(localeIdentifier: String) async {
        isCheckingAssets = true
        errorMessage = nil
        defer {
            isCheckingAssets = false
            assetStatusCheckTask = nil
            assetStatusCheckTaskLocale = nil
        }

        do {
            if let installedLocale = try await transcriber.installedLocaleIdentifier(
                localeIdentifier: localeIdentifier
            ), PreparedSpeechLocalePolicy.isPrepared(
                preparedIdentifier: installedLocale,
                requestedIdentifier: localeIdentifier,
                assetsInstalled: true
            ) {
                preparedLocaleIdentifier = installedLocale
                assetsPrepared = true
                defaults.set(installedLocale, forKey: Self.preparedSpeechLocaleDefaultsKey)
                return
            }

            preparedLocaleIdentifier = nil
            assetsPrepared = false
            defaults.removeObject(forKey: Self.preparedSpeechLocaleDefaultsKey)
        } catch {
            preparedLocaleIdentifier = nil
            assetsPrepared = false
            defaults.removeObject(forKey: Self.preparedSpeechLocaleDefaultsKey)
            errorMessage = error.localizedDescription
        }
    }

    func startRecording(
        backend: TranscriptionBackend,
        modelDirectory: URL?,
        languageIdentifier: String,
        vocabularyTerms: [String] = [],
        ctcVocabularyDirectory: URL? = nil,
        shouldContinueStarting: @MainActor () -> Bool = { true }
    ) async {
        completedRecordingAudioData = nil
        recordingVocabularyTerms = vocabularyTerms
        guard shouldContinueStarting() else { return }
        switch backend {
        case .appleSpeech:
            await startAppleSpeechRecording(
                languageIdentifier: languageIdentifier,
                shouldContinueStarting: shouldContinueStarting
            )
            if isRecording {
                recordingBackend = .appleSpeech
                recordingLanguageIdentifier = languageIdentifier
            }
        case .parakeetV3, .whisperLargeV3Turbo:
            guard let modelDirectory else {
                errorMessage = "The selected model is not installed. Download it from Speech Models, then try again."
                return
            }
            await startAudioOnlyRecording(
                previewEnabled: backend == .parakeetV3,
                shouldContinueStarting: shouldContinueStarting
            )
            if isRecording {
                recordingBackend = backend
                recordingModelDirectory = modelDirectory
                recordingCtcVocabularyDirectory = ctcVocabularyDirectory
                recordingLanguageIdentifier = languageIdentifier
                if backend == .parakeetV3, let previewAudio {
                    startParakeetPreview(audio: previewAudio, modelDirectory: modelDirectory,
                                         languageIdentifier: languageIdentifier)
                }
            }
        case .unavailable(let engineID):
            errorMessage = "The selected transcription engine is unavailable: \(engineID)."
        }
    }

    private func startAppleSpeechRecording(
        languageIdentifier: String,
        shouldContinueStarting: @MainActor () -> Bool
    ) async {
        guard !isRecording, !isTranscribing, shouldContinueStarting() else { return }
        guard isAppleSpeechPrepared(for: languageIdentifier) else {
            errorMessage = "Apple Speech assets for this language aren't installed yet. Choose Prepare Apple Speech in the Dictation panel, then use the hotkey again."
            return
        }
        errorMessage = nil

        let hasMicrophoneAccess = await microphoneAccessGranted()
        guard shouldContinueStarting() else { return }
        guard hasMicrophoneAccess else {
            errorMessage = "Microphone access is off. Allow EchoFlow in System Settings → Privacy & Security → Microphone."
            return
        }

        guard let preparedLocaleIdentifier else {
            errorMessage = "Apple Speech no longer reports installed assets for this language. Check the Dictation panel and choose Prepare Apple Speech, then use the hotkey again."
            return
        }
        let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: preparedLocaleIdentifier)
        )
        guard shouldContinueStarting() else { return }
        guard let locale else {
            errorMessage = "Apple Speech no longer reports installed assets for this language. Check the Dictation panel and choose Prepare Apple Speech, then use the hotkey again."
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let selectedMicrophoneName: String
        do {
            selectedMicrophoneName = try microphoneSettings.configure(inputNode: inputNode)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "The selected microphone is not ready. Check the audio input in System Settings."
            return
        }

        let liveTranscriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [liveTranscriber],
            considering: inputFormat
        )
        guard shouldContinueStarting() else { return }
        guard let analyzerFormat else {
            errorMessage = "Apple Speech could not choose an audio format for this microphone."
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowRecording-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let (inputSequence, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [liveTranscriber])
        let resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in liveTranscriber.results {
                    guard let self else { return }
                    self.liveTranscript.consume(
                        text: String(result.text.characters),
                        isFinal: result.isFinal
                    )
                    self.transcript = self.liveTranscript.visibleText
                    self.onChange?(self)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }

        var tapInstalled = false
        do {
            let writer = try AudioFileWriter(url: url, settings: inputFormat.settings)
            let converter = try SpeechAudioBufferConverter(inputFormat: inputFormat, outputFormat: analyzerFormat)
            let bridge = AudioAnalyzerInputBridge(converter: converter, continuation: continuation)

            if let context = AppleSpeechTranscriber.analysisContext(for: recordingVocabularyTerms) {
                try await analyzer.setContext(context)
            }
            guard shouldContinueStarting() else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                try? FileManager.default.removeItem(at: url)
                return
            }
            try await analyzer.start(inputSequence: inputSequence)
            guard shouldContinueStarting() else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                try? FileManager.default.removeItem(at: url)
                return
            }
            let tapHandler = AudioTapHandlerFactory.make { buffer in
                writer.write(buffer)
                bridge.append(buffer)
            }
            inputNode.installTap(
                onBus: 0,
                bufferSize: 2_048,
                format: inputFormat,
                block: tapHandler
            )
            tapInstalled = true
            engine.prepare()
            let microphoneAuthorized = Self.microphoneAuthorizationIsCurrentlyGranted()
            guard RecordingCaptureStartPolicy.canStartEngine(
                startIsCurrent: shouldContinueStarting(),
                microphoneAuthorized: microphoneAuthorized
            ) else {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
                engine.stop()
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                try? FileManager.default.removeItem(at: url)
                if !microphoneAuthorized {
                    errorMessage = "Microphone access was revoked before recording started. Allow EchoFlow in System Settings → Privacy & Security → Microphone."
                }
                return
            }
            try engine.start()

            audioEngine = engine
            audioWriter = writer
            recordingURL = url
            inputBridge = bridge
            speechAnalyzer = analyzer
            liveResultsTask = resultsTask
            microphoneName = selectedMicrophoneName
            transcript = ""
            liveTranscript.reset()
            isRecording = true
            onChange?(self)
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            continuation.finish(throwing: error)
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            try? FileManager.default.removeItem(at: url)
            if shouldContinueStarting() {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startAudioOnlyRecording(
        previewEnabled: Bool,
        shouldContinueStarting: @MainActor () -> Bool
    ) async {
        guard !isPreparingAssets, !isRecording, !isTranscribing, shouldContinueStarting() else { return }
        errorMessage = nil

        let hasMicrophoneAccess = await microphoneAccessGranted()
        guard shouldContinueStarting() else { return }
        guard hasMicrophoneAccess else {
            errorMessage = "Microphone access is off. Allow EchoFlow in System Settings → Privacy & Security → Microphone."
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let selectedMicrophoneName: String
        do {
            selectedMicrophoneName = try microphoneSettings.configure(inputNode: inputNode)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "The selected microphone is not ready. Check the audio input in System Settings."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowRecording-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        var tapInstalled = false
        do {
            let writer = try AudioFileWriter(url: url, settings: inputFormat.settings)
            let preview = previewEnabled
                ? ParakeetPreviewAudioQueue() : nil
            let tapHandler = AudioTapHandlerFactory.make { buffer in
                writer.write(buffer)
                preview?.append(buffer)
            }
            inputNode.installTap(
                onBus: 0,
                bufferSize: 2_048,
                format: inputFormat,
                block: tapHandler
            )
            tapInstalled = true
            engine.prepare()
            let microphoneAuthorized = Self.microphoneAuthorizationIsCurrentlyGranted()
            guard RecordingCaptureStartPolicy.canStartEngine(
                startIsCurrent: shouldContinueStarting(),
                microphoneAuthorized: microphoneAuthorized
            ) else {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
                engine.stop()
                try? FileManager.default.removeItem(at: url)
                if !microphoneAuthorized {
                    errorMessage = "Microphone access was revoked before recording started. Allow EchoFlow in System Settings → Privacy & Security → Microphone."
                }
                return
            }
            try engine.start()

            audioEngine = engine
            audioWriter = writer
            previewAudio = preview
            recordingURL = url
            microphoneName = selectedMicrophoneName
            transcript = ""
            liveTranscript.reset()
            isRecording = true
            onChange?(self)
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
        }
    }

    private func startParakeetPreview(
        audio: ParakeetPreviewAudioQueue, modelDirectory: URL, languageIdentifier: String
    ) {
        let token = tentativeTranscript.begin()
        previewToken = token
        let onUpdate: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.recordingBackend == .parakeetV3,
                      self.tentativeTranscript.accept(text, for: token) else { return }
                self.transcript = self.tentativeTranscript.text
                self.onChange?(self)
            }
        }
        previewTask = Task.detached(priority: .utility) {
            await ParakeetLivePreview.run(
                audio: audio, modelDirectory: modelDirectory,
                languageIdentifier: languageIdentifier, onUpdate: onUpdate
            )
        }
    }

    private func stopParakeetPreview() {
        if let previewToken { tentativeTranscript.stop(previewToken) }
        previewToken = nil
        previewTask?.cancel()
        previewTask = nil
        previewAudio?.finish()
        previewAudio = nil
        // Tentative words may never become a final transcript, even when batch fails.
        if recordingBackend == .parakeetV3 { transcript = "" }
    }

    func stopAndTranscribe(saveAudio: Bool = false) async {
        guard isRecording, let engine = audioEngine, let recordingURL else { return }
        if recordingBackend == .parakeetV3 { stopParakeetPreview() }
        isRecording = false
        isTranscribing = true
        onChange?(self)
        defer {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            self.recordingBackend = nil
            self.recordingModelDirectory = nil
            self.recordingCtcVocabularyDirectory = nil
            self.recordingLanguageIdentifier = nil
            self.recordingVocabularyTerms = []
            self.isTranscribing = false
            self.onChange?(self)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        if recordingBackend == .parakeetV3 {
            // Give cancellation/recognizer cleanup a short head start before the
            // independent batch manager loads the same installed model assets.
            // Never await previewTask.value here: Core ML inference may not cancel promptly.
            try? await Task.sleep(for: .milliseconds(200))
        }
        let writeError = audioWriter?.errorMessage
        audioWriter = nil
        if saveAudio, writeError == nil {
            completedRecordingAudioData = try? Data(contentsOf: recordingURL)
        }

        let bridge = inputBridge
        let bridgeError = bridge?.errorMessage
        bridge?.finish()
        inputBridge = nil
        if let bridgeError {
            errorMessage = "Live preview stopped early; the final local transcription will still run. \(bridgeError)"
        }
        let analyzer = speechAnalyzer
        speechAnalyzer = nil
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await liveResultsTask?.value
        liveResultsTask = nil

        let liveText = liveTranscript.visibleText
        if let writeError {
            transcript = recordingBackend == .parakeetV3 ? "" : liveText
            errorMessage = "Could not finish the temporary recording: \(writeError)"
            return
        }
        let languageIdentifier = recordingLanguageIdentifier ?? Locale.current.identifier
        do {
            switch recordingBackend {
            case .appleSpeech:
                guard let preparedLocaleIdentifier else {
                    transcript = liveText
                    errorMessage = "Apple Speech assets aren't installed for this language. Choose Prepare Apple Speech in the Dictation panel, then use the hotkey again."
                    return
                }
                let finalTranscript = try await transcriber.transcribe(
                    audioFileAt: recordingURL,
                    localeIdentifier: preparedLocaleIdentifier,
                    contextualPhrases: recordingVocabularyTerms
                )
                transcript = finalTranscript.isEmpty ? liveText : finalTranscript
            case .parakeetV3, .whisperLargeV3Turbo:
                guard let recordingModelDirectory, let backend = recordingBackend else {
                    throw LocalModelTranscriber.TranscriptionError.unavailableBackend(
                        String(describing: recordingBackend)
                    )
                }
                transcript = try await LocalModelTranscriber.transcribe(
                    backend: backend,
                    audioURL: recordingURL,
                    modelDirectory: recordingModelDirectory,
                    languageIdentifier: languageIdentifier,
                    vocabularyTerms: recordingVocabularyTerms,
                    ctcVocabularyDirectory: recordingCtcVocabularyDirectory
                )
            case .unavailable(let engineID):
                throw LocalModelTranscriber.TranscriptionError.unavailableBackend(engineID)
            case nil:
                throw LocalModelTranscriber.TranscriptionError.unavailableBackend("no selected engine")
            }
        } catch {
            transcript = recordingBackend == .parakeetV3 ? "" : liveText
            errorMessage = error.localizedDescription
        }
    }

    func takeCompletedRecordingAudioData() -> Data? {
        defer { completedRecordingAudioData = nil }
        return completedRecordingAudioData
    }

    func cancelAndDiscardRecording() async {
        guard isRecording, let recordingURL else { return }
        if recordingBackend == .parakeetV3 { stopParakeetPreview() }
        isRecording = false
        isTranscribing = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioWriter = nil
        completedRecordingAudioData = nil
        inputBridge?.finish()
        inputBridge = nil
        if let speechAnalyzer {
            await speechAnalyzer.cancelAndFinishNow()
        }
        speechAnalyzer = nil
        liveResultsTask?.cancel()
        liveResultsTask = nil
        try? FileManager.default.removeItem(at: recordingURL)
        self.recordingURL = nil
        liveTranscript.reset()
        transcript = ""
        recordingBackend = nil
        recordingModelDirectory = nil
        recordingCtcVocabularyDirectory = nil
        recordingLanguageIdentifier = nil
        recordingVocabularyTerms = []
        onChange?(self)
    }

    private static func microphoneAuthorizationIsCurrentlyGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private static func removeInterruptedRecordings() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("EchoFlowRecording-") && file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private var writeFailure: String?

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return writeFailure
    }

    init(url: URL, settings: [String: Any]) throws {
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard writeFailure == nil else { return }
        do {
            try file.write(from: buffer)
        } catch {
            writeFailure = error.localizedDescription
        }
    }
}

private final class AudioAnalyzerInputBridge: @unchecked Sendable {
    // The audio tap calls append; stop halts the engine before finish. Lock order is bridge → converter → input source, with no reverse acquisition path.
    private let lock = NSLock()
    private let converter: SpeechAudioBufferConverter
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private var finished = false
    private var failureMessage: String?

    init(
        converter: SpeechAudioBufferConverter,
        continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    ) {
        self.converter = converter
        self.continuation = continuation
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        do {
            let converted = try converter.convert(input)
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            finished = true
            failureMessage = error.localizedDescription
            continuation.finish(throwing: error)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureMessage
    }
}
