import AppKit
import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class EchoFlowRuntime {
    let dictation: SpeechDictationViewModel
    let modelLibrary: ModelLibraryViewModel
    let history: TranscriptHistoryViewModel
    let localLearning: LocalLearningViewModel
    let customVocabulary: CustomVocabularyViewModel
    let excludedApplications: ExcludedApplicationsViewModel
    let microphones: MicrophoneSettingsViewModel
    let hotkey: GlobalHotkeyController
    let overlayModel: RecordingOverlayModel
    let textInsertion: TextInsertionService
    let recordingFeedback: RecordingFeedbackController
    let recordingAudioOptions: RecordingAudioOptionsController
    let smartLinks: SmartLinksViewModel
    let launchAtLogin: LaunchAtLoginController
    let textCleanup: TranscriptTextCleanupViewModel
    let voiceMemoDestination: VoiceMemoDestinationController

    var deliveryMessage: String?
    var deliveryDebugInfo: String?

    var preferredTranscriptionLanguageIdentifier: String {
        TranscriptionLanguagePreference.resolve(
            UserDefaults.standard.string(forKey: "EchoFlow.transcriptionLanguage"),
            systemLanguageIdentifier: Locale.current.identifier
        )
    }

    var voiceRewriteAvailabilityMessage: String { voiceRewriteService.availabilityMessage }

    @ObservationIgnored private let overlayWindow: RecordingOverlayWindowController
    @ObservationIgnored private var dismissOverlayTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceActivationObserver: NSObjectProtocol?
    @ObservationIgnored private var recordingStartGate = RecordingStartGate()
    @ObservationIgnored private var isRecordingStartTaskInFlight = false
    @ObservationIgnored private var recordingDiscardGate = RecordingDiscardGate()
    @ObservationIgnored private var pendingRecordingActionKind: RecordingActionKind?
    @ObservationIgnored private var isDeliveringTranscript = false
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var recordingEngineID: String?
    @ObservationIgnored private var finalTranscriptOverride: String?
    @ObservationIgnored private var activeRecordingAction: ActiveRecordingAction = .dictation
    @ObservationIgnored private let voiceRewriteService = OnDeviceVoiceRewriteService()

    private enum ActiveRecordingAction {
        case dictation
        case voiceMemo(directory: URL)
        case rewrite(selection: CapturedRewriteSelection)

        var kind: RecordingActionKind {
            switch self {
            case .dictation: .dictation
            case .voiceMemo: .voiceMemo
            case .rewrite: .rewrite
            }
        }
    }

    init() {
        let microphones = MicrophoneSettingsViewModel()
        let dictation = SpeechDictationViewModel(microphoneSettings: microphones)
        let modelLibrary = ModelLibraryViewModel()
        let history = TranscriptHistoryViewModel()
        let localLearning = LocalLearningViewModel()
        let customVocabulary = CustomVocabularyViewModel()
        let smartLinks = SmartLinksViewModel()
        let launchAtLogin = LaunchAtLoginController()
        let textCleanup = TranscriptTextCleanupViewModel()
        let voiceMemoDestination = VoiceMemoDestinationController()
        let excludedApplications = ExcludedApplicationsViewModel()
        let overlayModel = RecordingOverlayModel()
        let recordingFeedback = RecordingFeedbackController()
        let recordingAudioOptions = RecordingAudioOptionsController()
        self.dictation = dictation
        self.modelLibrary = modelLibrary
        self.history = history
        self.localLearning = localLearning
        self.customVocabulary = customVocabulary
        self.excludedApplications = excludedApplications
        self.microphones = microphones
        self.overlayModel = overlayModel
        self.recordingFeedback = recordingFeedback
        self.recordingAudioOptions = recordingAudioOptions
        self.smartLinks = smartLinks
        self.launchAtLogin = launchAtLogin
        self.textCleanup = textCleanup
        self.voiceMemoDestination = voiceMemoDestination
        self.hotkey = GlobalHotkeyController()
        self.textInsertion = TextInsertionService()
        self.overlayWindow = RecordingOverlayWindowController(model: overlayModel)

        textInsertion.onTranscriptCorrection = { [weak localLearning] original, corrected in
            localLearning?.observeTranscriptCorrection(original: original, corrected: corrected)
        }

        dictation.onChange = { [weak self] state in
            self?.synchronizeOverlay(with: state)
        }
        hotkey.onToggleRecording = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.toggleDictationFromHotkey()
            }
        }
        hotkey.onStartRecording = { [weak self] in
            self?.startHotkeyRecording() ?? false
        }
        hotkey.onStopRecording = { [weak self] in
            self?.stopOrCancelHotkeyRecording(for: .dictation)
        }
        hotkey.onStartVoiceMemoRecording = { [weak self] in
            self?.startVoiceMemoHotkeyRecording() ?? false
        }
        hotkey.onStopVoiceMemoRecording = { [weak self] in
            self?.stopOrCancelHotkeyRecording(for: .voiceMemo)
        }
        hotkey.onStartVoiceRewriteRecording = { [weak self] in
            self?.startVoiceRewriteHotkeyRecording() ?? false
        }
        hotkey.onStopVoiceRewriteRecording = { [weak self] in
            self?.stopOrCancelHotkeyRecording(for: .rewrite)
        }
        hotkey.isVoiceActionInProgress = { [weak self] kind in
            guard let self else { return false }
            return self.pendingRecordingActionKind == kind
                || (self.dictation.isRecording && self.activeRecordingAction.kind == kind)
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWorkspaceActivation()
            }
        }
        hotkey.refreshPermission()
    }

    private func handleWorkspaceActivation() {
        hotkey.refreshPermission()
        textInsertion.cancelCorrectionObservationIfTargetIsInvalid()

        if let pendingActionKind = pendingRecordingActionKind {
            if textInsertion.isFrontmostAppExcluded(),
               let canceledAction = invalidatePendingRecordingStart(for: pendingActionKind) {
                self.finishCanceledRecordingStart(canceledAction)
            }
            return
        }

        if dictation.isRecording, activeRecordingAction.kind == .dictation {
            textInsertion.prepareFrontmostAppAccessibility()
        }
        guard dictation.isRecording,
              textInsertion.isFrontmostAppExcluded(),
              recordingDiscardGate.request() else { return }
        Task { @MainActor [weak self] in
            await self?.discardRecordingInExcludedApp()
        }
    }

    private func startVoiceMemoHotkeyRecording() -> Bool {
        guard canStartVoiceAction() else { return false }
        guard !textInsertion.isFrontmostAppExcludedForVoiceAction() else {
            showVoiceActionMessage("Voice Memo is disabled while an excluded app is frontmost or its safety settings cannot be verified.")
            return false
        }
        guard let directory = voiceMemoDestination.resolvedDirectory() else {
            showVoiceActionMessage(voiceMemoDestination.errorMessage ?? "Choose a voice memo folder in Settings before recording.")
            return false
        }
        return beginVoiceAction(.voiceMemo(directory: directory))
    }

    private func startVoiceRewriteHotkeyRecording() -> Bool {
        guard canStartVoiceAction() else { return false }
        switch textInsertion.captureRewriteSelection() {
        case .success(let selection):
            return beginVoiceAction(.rewrite(selection: selection))
        case .failure(let decision):
            showVoiceActionMessage(Self.message(for: decision))
            return false
        }
    }

    private func canStartVoiceAction() -> Bool {
        guard !recordingDiscardGate.blocksRecordingEvents,
              !dictation.isRecording,
              !dictation.isTranscribing,
              !isDeliveringTranscript,
              !isRecordingStartTaskInFlight else {
            deliveryMessage = "Finish the current recording before starting another voice action."
            return false
        }
        return true
    }

    private func beginVoiceAction(_ action: ActiveRecordingAction) -> Bool {
        guard !isRecordingStartTaskInFlight,
              let startToken = recordingStartGate.begin() else { return false }
        isRecordingStartTaskInFlight = true
        pendingRecordingActionKind = action.kind
        Task { @MainActor [weak self] in
            await self?.startRecording(startToken: startToken, action: action)
        }
        return true
    }

    private func startHotkeyRecording() -> Bool {
        guard !recordingDiscardGate.blocksRecordingEvents,
              !dictation.isRecording,
              !dictation.isTranscribing,
              !isDeliveringTranscript,
              !isRecordingStartTaskInFlight,
              let startToken = recordingStartGate.begin() else { return false }
        isRecordingStartTaskInFlight = true
        pendingRecordingActionKind = .dictation
        Task { @MainActor [weak self] in
            await self?.startRecording(startToken: startToken, action: .dictation)
        }
        return true
    }

    func startRecording() async {
        guard !recordingDiscardGate.blocksRecordingEvents,
              !dictation.isRecording,
              !dictation.isTranscribing,
              !isDeliveringTranscript,
              !isRecordingStartTaskInFlight,
              let startToken = recordingStartGate.begin() else { return }
        isRecordingStartTaskInFlight = true
        pendingRecordingActionKind = .dictation
        await startRecording(startToken: startToken, action: .dictation)
    }

    private func startRecording(startToken: UInt64, action: ActiveRecordingAction) async {
        defer {
            recordingStartGate.finish(startToken)
            isRecordingStartTaskInFlight = false
            pendingRecordingActionKind = nil
        }
        guard recordingStartGate.isCurrent(startToken) else { return }
        guard !dictation.isRecording, !dictation.isTranscribing, !isDeliveringTranscript else {
            if action.kind != .dictation {
                showVoiceActionMessage("Finish the current recording before starting another voice action.")
            }
            return
        }

        let startTargetIsExcluded = action.kind == .dictation
            ? textInsertion.isFrontmostAppExcluded()
            : textInsertion.isFrontmostAppExcludedForVoiceAction()
        guard !startTargetIsExcluded else {
            reportRecordingStartFailure(
                action.kind == .dictation
                    ? "Dictation is disabled while an excluded app is frontmost or its safety settings cannot be verified."
                    : "Voice actions are disabled while an excluded app is frontmost.",
                action: action
            )
            return
        }
        guard let catalog = modelLibrary.catalog else {
            reportRecordingStartFailure(
                modelLibrary.startupError ?? "The speech model catalog is unavailable.",
                action: action
            )
            return
        }
        let engineID = modelLibrary.selectedEngineID
        let backend = TranscriptionBackend.resolve(
            engineID: engineID,
            catalog: catalog,
            installedDownloadIDs: modelLibrary.installedDownloadIDs
        )
        if case .unavailable(let unavailableEngineID) = backend {
            reportRecordingStartFailure(
                "The selected transcription engine is unavailable: \(unavailableEngineID).",
                action: action
            )
            return
        }
        let modelDirectory = modelLibrary.installedModelDirectory(for: engineID)
        let languageIdentifier = preferredTranscriptionLanguageIdentifier
        if backend == .appleSpeech {
            await dictation.checkAppleSpeechAssets(localeIdentifier: languageIdentifier)
            guard recordingStartGate.isCurrent(startToken) else { return }
            guard dictation.isAppleSpeechPrepared(for: languageIdentifier) else {
                reportRecordingStartFailure(
                    dictation.errorMessage
                        ?? "Apple Speech assets aren't installed for this language yet. Choose Prepare Apple Speech in the Dictation panel, then use the hotkey again.",
                    action: action
                )
                return
            }
        }
        if backend != .appleSpeech, modelDirectory == nil {
            reportRecordingStartFailure(
                "The selected local model is not installed or failed verification. Reinstall it from Speech Models.",
                action: action
            )
            return
        }
        let captureTargetIsExcluded = action.kind == .dictation
            ? textInsertion.isFrontmostAppExcluded()
            : textInsertion.isFrontmostAppExcludedForVoiceAction()
        guard recordingStartGate.isCurrent(startToken), !captureTargetIsExcluded else {
            reportRecordingStartFailure(
                action.kind == .dictation
                    ? "Dictation was canceled because the foreground app changed to an excluded app before recording started."
                    : "Voice action was canceled because the foreground app changed to an excluded app or its safety settings could not be verified.",
                action: action
            )
            return
        }
        if action.kind == .dictation {
            textInsertion.prepareFrontmostAppAccessibility()
        }
        dismissOverlayTask?.cancel()
        finalTranscriptOverride = nil
        deliveryMessage = nil
        deliveryDebugInfo = nil
        overlayModel.deliveryMessage = nil
        overlayModel.deliveryDebugInfo = nil
        let vocabularyTerms = TranscriptionVocabulary.terms(
            customTerms: customVocabulary.store.terms.map(\.term),
            learnedTerms: localLearning.store.learnedTerms
        )
        await dictation.startRecording(
            backend: backend,
            modelDirectory: modelDirectory,
            languageIdentifier: languageIdentifier,
            vocabularyTerms: vocabularyTerms,
            ctcVocabularyDirectory: backend == .parakeetV3
                ? modelLibrary.installedModelDirectory(
                    forDownloadID: ModelLibraryViewModel.parakeetVocabularyDownloadID
                )
                : nil,
            shouldContinueStarting: { [weak self] in
                guard let self else { return false }
                return self.validatePendingRecordingStart(startToken, action: action)
            }
        )
        guard recordingStartGate.isCurrent(startToken) else {
            if dictation.isRecording {
                await dictation.cancelAndDiscardRecording()
                overlayModel.phase = .idle
                overlayWindow.hide()
                deliveryMessage = "Dictation start was canceled before audio setup finished."
            }
            return
        }
        if dictation.isRecording {
            activeRecordingAction = action
            recordingStartedAt = Date()
            recordingEngineID = engineID
            switch action {
            case .dictation:
                break
            case .voiceMemo:
                deliveryMessage = "Voice Memo recording — tap \(hotkey.selectedKeyName) or press \(hotkey.voiceMemoShortcut.displayLabel ?? "the Voice Memo shortcut") again to save."
            case .rewrite:
                deliveryMessage = "Voice Rewrite recording — speak the editing instruction, then tap \(hotkey.selectedKeyName) or press \(hotkey.rewriteShortcut.displayLabel ?? "the Rewrite shortcut") again."
            }
            overlayModel.deliveryMessage = deliveryMessage
            recordingAudioOptions.startRecording()
            recordingFeedback.recordingStarted()
        }
    }

    private func invalidatePendingRecordingStart(
        for actionKind: RecordingActionKind? = nil
    ) -> RecordingActionKind? {
        guard isRecordingStartTaskInFlight,
              let pendingRecordingActionKind,
              actionKind == nil || actionKind == pendingRecordingActionKind,
              recordingStartGate.cancelPending() else {
            return nil
        }
        return pendingRecordingActionKind
    }

    private func finishCanceledRecordingStart(_ actionKind: RecordingActionKind) {
        switch actionKind {
        case .dictation:
            deliveryMessage = "Dictation start canceled because the hotkey was released before setup finished."
        case .voiceMemo:
            showVoiceActionMessage("Voice Memo canceled before recording finished setting up.")
        case .rewrite:
            showVoiceActionMessage("Voice Rewrite canceled before recording finished setting up.")
        }
    }

    private func cancelPendingRecordingStart(for actionKind: RecordingActionKind? = nil) -> Bool {
        guard let canceledAction = invalidatePendingRecordingStart(for: actionKind) else { return false }
        finishCanceledRecordingStart(canceledAction)
        return true
    }

    private func stopOrCancelHotkeyRecording(for actionKind: RecordingActionKind) {
        let decision = RecordingActionEventPolicy.decision(
            requestedAction: actionKind,
            pendingAction: pendingRecordingActionKind,
            activeAction: activeRecordingAction.kind
        )
        switch decision {
        case .cancelPendingStart:
            if let canceledAction = invalidatePendingRecordingStart(for: actionKind) {
                finishCanceledRecordingStart(canceledAction)
            }
            return
        case .ignore:
            return
        case .stopActiveRecording:
            guard !recordingDiscardGate.blocksRecordingEvents else { return }
            Task { @MainActor [weak self] in
                await self?.stopAndDeliverRecording()
            }
        }
    }

    private func toggleDictationFromHotkey() async {
        guard !isDeliveringTranscript,
              pendingRecordingActionKind == nil || pendingRecordingActionKind == .dictation,
              !dictation.isRecording || activeRecordingAction.kind == .dictation else {
            return
        }
        await toggleRecording()
    }

    func toggleRecording() async {
        guard !recordingDiscardGate.blocksRecordingEvents,
              DictationTogglePolicy.canToggleDictation(
                  isRecording: dictation.isRecording,
                  activeRecordingIsDictation: activeRecordingAction.kind == .dictation,
                  hasPendingRecordingStart: pendingRecordingActionKind != nil,
                  pendingRecordingStartIsDictation: pendingRecordingActionKind == .dictation
              ) else { return }
        if dictation.isRecording {
            if cancelPendingRecordingStart(for: .dictation) { return }
            await stopAndDeliverRecording()
            return
        }
        if cancelPendingRecordingStart(for: .dictation) { return }
        guard !dictation.isTranscribing else { return }
        await startRecording()
    }

    func stopAndDeliverRecording() async {
        guard !recordingDiscardGate.blocksRecordingEvents,
              dictation.isRecording else { return }
        let action = activeRecordingAction
        let recordingIsInExcludedApp = action.kind == .dictation
            ? textInsertion.isFrontmostAppExcluded()
            : textInsertion.isFrontmostAppExcludedForVoiceAction()
        if recordingIsInExcludedApp {
            guard recordingDiscardGate.request() else { return }
            await discardRecordingInExcludedApp()
            recordingStartedAt = nil
            recordingEngineID = nil
            return
        }
        let insertionTargetAtStop: CapturedDeliveryTarget?
        if case .dictation = action {
            insertionTargetAtStop = textInsertion.captureDeliveryTarget()
        } else {
            insertionTargetAtStop = nil
        }
        isDeliveringTranscript = true
        overlayModel.phase = .finishing
        if recordingEngineID == ModelLibraryViewModel.whisperEngineID,
           modelLibrary.whisperPreparation != .ready {
            overlayModel.deliveryMessage = "Preparing Whisper for first use. This one-time step can take a few minutes after a new install."
        }
        overlayWindow.show()
        recordingAudioOptions.stopRecording()
        recordingFeedback.recordingStopped()
        let shouldSaveAudio: Bool
        if case .dictation = action {
            shouldSaveAudio = history.settings.historyEnabled && history.settings.saveAudio
        } else {
            shouldSaveAudio = false
        }
        await dictation.stopAndTranscribe(saveAudio: shouldSaveAudio)

        switch action {
        case .voiceMemo(let directory):
            _ = dictation.takeCompletedRecordingAudioData()
            let memoTimestamp = recordingStartedAt ?? Date()
            recordingStartedAt = nil
            recordingEngineID = nil
            guard !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finishVoiceAction(
                    message: dictation.errorMessage ?? "No speech was recognized; no voice memo was saved.",
                    displayText: ""
                )
                return
            }
            do {
                let noteURL = try VoiceMemoNoteWriter().write(
                    dictation.transcript,
                    to: directory,
                    timestamp: memoTimestamp
                )
                finishVoiceAction(message: "Voice memo saved as \(noteURL.lastPathComponent).", displayText: dictation.transcript)
            } catch {
                finishVoiceAction(message: "Voice memo could not be saved: \(error.localizedDescription)", displayText: dictation.transcript)
            }
            return

        case .rewrite(let selection):
            _ = dictation.takeCompletedRecordingAudioData()
            recordingStartedAt = nil
            recordingEngineID = nil
            let instruction = dictation.transcript
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finishVoiceAction(
                    message: dictation.errorMessage ?? "No rewrite instruction was recognized; the selected text was left unchanged.",
                    displayText: ""
                )
                return
            }
            guard let rewrittenText = await voiceRewriteService.rewrite(
                selectedText: selection.snapshot.selectedText,
                instruction: instruction
            ) else {
                finishVoiceAction(
                    message: "Rewrite canceled: on-device Apple Intelligence is unavailable or did not return a valid result. The selected text was left unchanged.",
                    displayText: instruction
                )
                return
            }
            let replacement = await textInsertion.replaceSelectedText(with: rewrittenText, captured: selection)
            finishVoiceAction(message: Self.message(for: replacement), displayText: rewrittenText)
            return

        case .dictation:
            break
        }

        let transcriptAfterCleanup = await textCleanup.cleanedText(
            dictation.transcript,
            targetBundleIdentifier: insertionTargetAtStop?.snapshot.bundleIdentifier
        )
        let finalTranscript = smartLinks.applying(to: transcriptAfterCleanup)
        finalTranscriptOverride = finalTranscript
        overlayModel.transcript = finalTranscript
        let duration = max(0, Date().timeIntervalSince(recordingStartedAt ?? Date()))
        recordingStartedAt = nil
        let audioData = dictation.takeCompletedRecordingAudioData()
        if !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try history.saveTranscript(
                    finalTranscript,
                    duration: duration,
                    modelID: recordingEngineID ?? modelLibrary.selectedEngineID,
                    audioData: audioData
                )
            } catch {
                history.errorMessage = "Transcript was recognized but history could not be saved: \(error.localizedDescription)"
            }
        }
        recordingEngineID = nil
        guard !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deliveryMessage = dictation.errorMessage ?? "No speech was recognized; nothing was inserted."
            overlayModel.deliveryMessage = deliveryMessage
            isDeliveringTranscript = false
            synchronizeOverlay(with: dictation)
            return
        }
        let report = await textInsertion.deliver(
            finalTranscript,
            capturedTarget: insertionTargetAtStop,
            autoSend: UserDefaults.standard.bool(forKey: "EchoFlow.autoSend")
        )
        deliveryMessage = Self.message(for: report.outcome)
        deliveryDebugInfo = report.debugInfo
        overlayModel.deliveryMessage = report.needsDeliveryNotice ? deliveryMessage : nil
        overlayModel.deliveryDebugInfo = report.needsDeliveryNotice ? report.debugInfo : nil
        isDeliveringTranscript = false
        synchronizeOverlay(with: dictation)
    }

    private func validatePendingRecordingStart(
        _ startToken: UInt64,
        action: ActiveRecordingAction
    ) -> Bool {
        let startIsCurrent = recordingStartGate.isCurrent(startToken)
        let targetIsExcluded = action.kind == .dictation
            ? textInsertion.isFrontmostAppExcluded()
            : textInsertion.isFrontmostAppExcludedForVoiceAction()
        guard RecordingCaptureStartPolicy.canCapture(
            startIsCurrent: startIsCurrent,
            targetIsExcluded: targetIsExcluded
        ) else {
            guard startIsCurrent, targetIsExcluded else { return false }
            _ = recordingStartGate.cancelPending()
            reportRecordingStartFailure(
                action.kind == .dictation
                    ? "Dictation was canceled because the foreground app changed to an excluded app before audio capture began."
                    : "Voice action was canceled because the foreground app changed to an excluded app or its safety settings could not be verified before audio capture began.",
                action: action
            )
            return false
        }
        return true
    }

    private func reportRecordingStartFailure(_ message: String, action: ActiveRecordingAction) {
        dictation.errorMessage = message
        if action.kind != .dictation {
            showVoiceActionMessage(message)
        }
    }

    private func showVoiceActionMessage(_ message: String) {
        finalTranscriptOverride = nil
        deliveryMessage = message
        deliveryDebugInfo = nil
        overlayModel.transcript = ""
        overlayModel.phase = .done
        overlayModel.deliveryMessage = message
        overlayModel.deliveryDebugInfo = nil
        overlayWindow.show()
        dismissOverlayTask?.cancel()
        dismissOverlayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.overlayWindow.hide()
        }
    }

    private func finishVoiceAction(message: String, displayText: String) {
        activeRecordingAction = .dictation
        recordingStartedAt = nil
        recordingEngineID = nil
        finalTranscriptOverride = displayText
        deliveryMessage = message
        deliveryDebugInfo = nil
        overlayModel.transcript = displayText
        overlayModel.deliveryMessage = message
        overlayModel.deliveryDebugInfo = nil
        isDeliveringTranscript = false
        if displayText.isEmpty {
            overlayModel.phase = .done
            overlayWindow.show()
            dismissOverlayTask?.cancel()
            dismissOverlayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.overlayWindow.hide()
            }
        } else {
            synchronizeOverlay(with: dictation)
        }
    }

    private func discardRecordingInExcludedApp() async {
        guard recordingDiscardGate.beginCleanup() else { return }
        guard dictation.isRecording else {
            recordingDiscardGate.finishCleanup()
            return
        }
        defer { recordingDiscardGate.finishCleanup() }
        let action = activeRecordingAction
        recordingAudioOptions.stopRecording()
        recordingFeedback.recordingStopped()
        let target: CapturedDeliveryTarget?
        if case .dictation = action {
            target = textInsertion.captureDeliveryTarget()
        } else {
            target = nil
        }
        await dictation.cancelAndDiscardRecording()
        recordingStartedAt = nil
        recordingEngineID = nil
        activeRecordingAction = .dictation
        if case .dictation = action {
            deliveryMessage = "Not inserted: dictation was discarded because an excluded app became active."
            let appName = target?.snapshot.applicationName ?? "Unknown"
            let focusType = target?.focusedElementType ?? "Unavailable (no frontmost application)"
            deliveryDebugInfo = "Frontmost app: \(appName)\nFocused element type: \(focusType)\nInsertion skipped: Dictation was discarded before transcription because an excluded app became active."
        } else if case .voiceMemo = action {
            deliveryMessage = "Voice memo canceled because an excluded app became active; no note was saved."
            deliveryDebugInfo = nil
        } else {
            deliveryMessage = "Voice rewrite canceled because an excluded app became active; the selected text was left unchanged."
            deliveryDebugInfo = nil
        }
        overlayModel.phase = .done
        overlayModel.deliveryMessage = deliveryMessage
        overlayModel.deliveryDebugInfo = deliveryDebugInfo
        overlayWindow.show()
        dismissOverlayTask?.cancel()
        dismissOverlayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.overlayWindow.hide()
        }
    }

    private func synchronizeOverlay(with dictation: SpeechDictationViewModel) {
        overlayModel.transcript = finalTranscriptOverride ?? dictation.transcript

        // Recording can also end without a hotkey (for example a microphone error); the dock
        // badge, stop cue, and music/volume changes follow the overlay in every case.
        if !dictation.isRecording, recordingFeedback.isRecording {
            recordingAudioOptions.stopRecording()
            recordingFeedback.recordingStopped()
        }

        if dictation.isRecording {
            dismissOverlayTask?.cancel()
            overlayModel.phase = .recording
            overlayWindow.show()
        } else if dictation.isTranscribing || isDeliveringTranscript {
            dismissOverlayTask?.cancel()
            overlayModel.phase = .finishing
            overlayWindow.show()
        } else if !dictation.transcript.isEmpty {
            overlayModel.phase = .done
            overlayWindow.show()
            dismissOverlayTask?.cancel()
            let hideDelay: Duration = overlayModel.deliveryMessage == nil ? .milliseconds(1200) : .seconds(5)
            dismissOverlayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: hideDelay)
                guard !Task.isCancelled else { return }
                self?.overlayWindow.hide()
            }
        } else {
            overlayModel.phase = .idle
            overlayWindow.hide()
        }
    }

    private static func message(for decision: RewriteSelectionDecision) -> String {
        switch decision {
        case .allowed:
            "Select text before using Voice Rewrite."
        case .noSelection:
            "Voice Rewrite needs selected text in the frontmost text field."
        case .unsupportedField:
            "Voice Rewrite could not verify an eligible text field. The selected text was not read or changed."
        case .secureField:
            "Voice Rewrite is unavailable in secure fields."
        case .excludedApplication:
            "Voice Rewrite is unavailable while an excluded app is frontmost."
        case .policyUnavailable:
            "Voice Rewrite is paused because EchoFlow could not verify the excluded-app settings. Reopen Settings and try again."
        case .invalidRange:
            "Voice Rewrite could not verify the selected text range; nothing was changed."
        case .selectionTooLarge:
            "The selected text is too long for Voice Rewrite. Nothing was changed."
        }
    }

    private static func message(for outcome: RewriteSelectionReplacementOutcome) -> String {
        switch outcome {
        case .replacedByAccessibility:
            "The original selection was replaced with the on-device rewrite."
        case .insertedByKeyboardEvents:
            "Unicode text input was sent to the verified original selection; EchoFlow cannot confirm whether the app accepted it."
        case .selectionChanged:
            "Rewrite canceled because the selected text, field, or app changed. The original selection was left alone."
        case .targetUnavailable:
            "Rewrite canceled because the original text field is no longer available."
        case .failed:
            "Rewrite could not be applied. The original selection was left alone."
        }
    }

    private static func message(for outcome: TextInsertionService.Outcome) -> String {
        switch outcome {
        case .inserted:
            "Accessibility inserted text into the verified field."
        case .insertedViaKeyboardEvents:
            "Unicode text input was sent to the same foreground app; EchoFlow cannot confirm whether the app accepted it."
        case .insertedAndSubmitted:
            "Text was inserted into the verified field and Return was sent."
        case .blocked(.targetUnavailable):
            "Not inserted: EchoFlow could not verify the foreground app when dictation stopped and text was ready. Use Copy in the transcript only if needed."
        case .blocked(.targetChanged):
            "Not inserted: the foreground app changed before the text was ready. Use Copy in the transcript only if needed."
        case .blocked(.excludedApplication):
            "Not inserted in an excluded application."
        case .blocked(.secureField):
            "Not inserted: the focused control is marked as a secure field."
        case .blocked(.unsupportedField):
            "Not inserted: EchoFlow could not verify that the focused control is a text field."
        case .blocked(.policyUnavailable):
            "Not inserted: EchoFlow could not verify the app identity or excluded-app policy."
        case .failed:
            "Text could not be inserted. The transcript remains available in EchoFlow."
        }
    }
}
