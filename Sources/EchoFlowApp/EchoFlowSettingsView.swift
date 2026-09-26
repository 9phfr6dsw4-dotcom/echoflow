import AppKit
import EchoFlowCore
import SwiftUI
import UniformTypeIdentifiers

struct EchoFlowSettingsView: View {
    @Environment(EchoFlowRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingClearConfirmation = false
    @State private var voiceActionShortcutError: String?
    @AppStorage("EchoFlow.showLiveWords") private var showLiveWords = true
    @AppStorage(RecordingFeedbackController.dockIconPreferenceKey) private var changeDockIconWhileRecording = false
    @AppStorage(RecordingFeedbackController.soundsPreferenceKey) private var playRecordingSounds = false
    @AppStorage(RecordingFeedbackController.soundVolumePreferenceKey) private var recordingSoundVolume = RecordingSoundVolumePolicy.defaultLevel
    @AppStorage(TextInsertionService.correctionLearningPreferenceKey) private var learnRecentInsertionCorrections = false
    @AppStorage("EchoFlow.transcriptionLanguage") private var transcriptionLanguage = ""
    @State private var newVocabularyTerm = ""
    @State private var vocabularyDrafts: [UUID: String] = [:]
    @State private var newSmartLinkPhrase = ""
    @State private var newSmartLinkURL = ""
    @State private var smartLinkPhraseDrafts: [UUID: String] = [:]
    @State private var smartLinkURLDrafts: [UUID: String] = [:]

    private var history: TranscriptHistoryViewModel { runtime.history }
    private var excludedApps: ExcludedApplicationsViewModel { runtime.excludedApplications }
    private var microphones: MicrophoneSettingsViewModel { runtime.microphones }
    private var learning: LocalLearningViewModel { runtime.localLearning }
    private var vocabulary: CustomVocabularyViewModel { runtime.customVocabulary }
    private var modelLibrary: ModelLibraryViewModel { runtime.modelLibrary }
    private var recordingAudioOptions: RecordingAudioOptionsController { runtime.recordingAudioOptions }
    private var smartLinks: SmartLinksViewModel { runtime.smartLinks }
    private var launchAtLogin: LaunchAtLoginController { runtime.launchAtLogin }
    private var textCleanup: TranscriptTextCleanupViewModel { runtime.textCleanup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.largeTitle.weight(.semibold))
                    Text("Keep control over local data and where EchoFlow can dictate.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                launchAtLoginSettings
                historySettings
                microphoneSettings
                transcriptionLanguageSettings
                excludedApplicationsSettings
                localLearningSettings
                customVocabularySettings
                smartLinkSettings
                voiceActionsSettings
                textCleanupSettings
                recordingBehaviorSettings
                recordingAudioSettings

                Label("Speech and transcripts stay on this Mac. EchoFlow does not use accounts, analytics, or cloud transcription.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Clear all EchoFlow transcript data?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Transcript Data", role: .destructive) {
                do {
                    try history.clearAll()
                } catch {
                    history.errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes EchoFlow transcript history and audio recordings, but does not delete Markdown archive files in your chosen folder or learned words. Files outside EchoFlow's transcript store are kept.")
        }
        .onAppear {
            runtime.overlayModel.showLiveWords = showLiveWords
            runtime.recordingFeedback.setDockIconChangeEnabled(changeDockIconWhileRecording)
            runtime.textInsertion.setCorrectionLearningEnabled(learnRecentInsertionCorrections)
            launchAtLogin.refreshStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { launchAtLogin.refreshStatus() }
        }
        .onChange(of: showLiveWords) { _, enabled in
            runtime.overlayModel.showLiveWords = enabled
        }
        .onChange(of: changeDockIconWhileRecording) { _, enabled in
            runtime.recordingFeedback.setDockIconChangeEnabled(enabled)
        }
        .onChange(of: learnRecentInsertionCorrections) { _, enabled in
            runtime.textInsertion.setCorrectionLearningEnabled(enabled)
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    private var launchAtLoginSettings: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch EchoFlow at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Text("On by default for a new installation. macOS may ask you to approve EchoFlow in System Settings → General → Login Items & Extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = launchAtLogin.statusMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Login Items") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var historySettings: some View {
        GroupBox("Transcript history and storage") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Keep transcript history on this Mac", isOn: setting(\.historyEnabled))
                Picker("Delete transcripts after", selection: setting(\.retention)) {
                    Text("7 days").tag(TranscriptHistoryRetention.sevenDays)
                    Text("30 days").tag(TranscriptHistoryRetention.thirtyDays)
                    Text("90 days").tag(TranscriptHistoryRetention.ninetyDays)
                    Text("Forever").tag(TranscriptHistoryRetention.forever)
                }
                .disabled(!history.settings.historyEnabled)
                Toggle("Save audio recordings (off by default)", isOn: setting(\.saveAudio))
                    .disabled(!history.settings.historyEnabled)
                Text("Audio is saved only with history enabled and is removed by the same retention policy. Learned words are stored separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Archive each transcript as Markdown", isOn: Binding(
                    get: { history.archiveDirectoryPath != nil },
                    set: { enabled in
                        if enabled { chooseArchiveDirectory() }
                        else { history.archiveDirectoryPath = nil }
                    }
                ))
                Text("Markdown archiving is independent of local history and retention. When a folder is selected, each recognized transcript is archived there even if local history is off; clearing EchoFlow history does not delete those archive files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let path = history.archiveDirectoryPath {
                    HStack {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Choose Folder…", action: chooseArchiveDirectory)
                    }
                }

                HStack {
                    Button("Clear All Data…", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    Spacer()
                    Text("\(history.records.count) saved transcripts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = history.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var supportedPinnedLanguages: [SupportedLanguage] {
        guard let catalog = modelLibrary.catalog,
              let engine = catalog.engine(id: ModelSelection.parakeetEngineID) else {
            return []
        }
        return engine.supportedLanguages.sorted { $0.name < $1.name }
    }

    private var transcriptionLanguageSettings: some View {
        GroupBox("Transcription language") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Preferred language", selection: $transcriptionLanguage) {
                    Text("Automatic (current Mac language)").tag("")
                    if !transcriptionLanguage.isEmpty,
                       !supportedPinnedLanguages.contains(where: { $0.code == transcriptionLanguage }) {
                        Text("Other — \(transcriptionLanguage)").tag(transcriptionLanguage)
                    }
                    ForEach(supportedPinnedLanguages) { language in
                        Text("\(language.name) (\(language.code))").tag(language.code)
                    }
                }
                Text("The pinned language is passed to the selected engine. The list shows Parakeet v3's supported languages; Automatic uses your Mac's current language for Apple Speech and Whisper. If Parakeet cannot support the selected or automatic language, EchoFlow shows an error instead of silently switching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var excludedApplicationsSettings: some View {
        GroupBox("Excluded apps") {
            VStack(alignment: .leading, spacing: 12) {
                Text("EchoFlow will not record or insert text while an excluded app is active. Password managers are excluded by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                List {
                    Section("Always excluded") {
                        ForEach(excludedApps.policy.defaultExcludedApplications, id: \.bundleIdentifier) { app in
                            Label(app.displayName, systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Your exclusions") {
                        if excludedApps.policy.userExcludedApplications.isEmpty {
                            Text("No additional apps excluded")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(excludedApps.policy.userExcludedApplications, id: \.bundleIdentifier) { app in
                            HStack {
                                Label(app.displayName, systemImage: "app.badge")
                                Spacer()
                                Button("Remove") {
                                    excludedApps.removeApplication(bundleIdentifier: app.bundleIdentifier)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(minHeight: 170, maxHeight: 260)

                HStack {
                    Button("Add Installed App…", action: chooseExcludedApplication)
                    Spacer()
                }
                if let errorMessage = excludedApps.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var localLearningSettings: some View {
        GroupBox("Local learning") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Learn corrections made to recent EchoFlow insertions",
                    isOn: $learnRecentInsertionCorrections
                )
                Text("Off by default. When enabled, EchoFlow watches the same field it just inserted into for up to 10 seconds. It considers only a selected range wholly inside that insertion, waits 800 ms after a value change, and reads only the validated replacement range. It never reads whole-field text, window titles, URLs, secure fields, or excluded apps. If Accessibility range, notification, or target checks are unavailable or ambiguous, nothing is learned. Accepted one-word corrections use the existing local-learning rule and need at least three repeats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Ask me before adding learned words", isOn: Binding(
                    get: { learning.askBeforeAdding },
                    set: { learning.askBeforeAdding = $0 }
                ))
                Text("EchoFlow learns only from explicit corrections you save in transcript history. The same correction must appear at least three times; short common words are ignored. Learned words stay on this Mac and are kept when transcript history is cleared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !learning.store.pendingAdditions.isEmpty {
                    Divider()
                    Text("Needs your confirmation")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(learning.store.pendingAdditions.enumerated()), id: \.offset) { entry in
                        let item = entry.element
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.term).font(.body.weight(.medium))
                                Text("Correction: \(item.original) → \(item.term) · \(item.occurrenceCount) times")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { _ = learning.confirmAddition(of: item.term) }
                            Button("Ignore", role: .destructive) { _ = learning.rejectAddition(of: item.term) }
                        }
                    }
                }

                Divider()
                HStack {
                    Text("Learned words")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(learning.store.learnedTerms.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if learning.store.learnedTerms.isEmpty {
                    Text("No learned words yet. Correct and save a transcript to teach EchoFlow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learning.store.learnedTerms) { term in
                        HStack {
                            Text(term.term)
                            Text("· \(term.occurrenceCount) corrections")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(term.isPinned ? "Unpin" : "Pin") {
                                _ = learning.setPinned(!term.isPinned, for: term.term)
                            }
                            Button("Remove", role: .destructive) {
                                _ = learning.removeLearnedTerm(term.term)
                            }
                        }
                    }
                }

                if let errorMessage = learning.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var customVocabularySettings: some View {
        GroupBox("Custom vocabulary") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add names and unusual words to bias supported local speech engines. Apple Speech uses up to 100 contextual phrases; Whisper uses decoder prompt tokens; Parakeet uses CTC contextual rescoring. Parakeet's vocabulary files are included in its model installation and are removed with it. Adding or editing a term never starts a download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("Name or unusual word", text: $newVocabularyTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addVocabularyTerm)
                    Button("Add", action: addVocabularyTerm)
                        .disabled(!vocabulary.canMutate || newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if vocabulary.store.terms.isEmpty {
                    Text("No custom terms yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vocabulary.store.terms) { term in
                        HStack(spacing: 8) {
                            TextField("Vocabulary term", text: vocabularyBinding(for: term))
                                .textFieldStyle(.roundedBorder)
                                .disabled(!vocabulary.canMutate)
                            Button("Save") { saveVocabularyTerm(term) }
                                .disabled(!vocabulary.canMutate)
                            Button("Remove", role: .destructive) { removeVocabularyTerm(term) }
                                .disabled(!vocabulary.canMutate)
                        }
                    }
                }

                if let errorMessage = vocabulary.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var smartLinkSettings: some View {
        GroupBox("Smart links") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save a phrase and its link. When you say the phrase, EchoFlow replaces it with the URL in the final transcript before saving or inserting it. Matching is case-insensitive and only replaces the complete phrase. This works locally with every speech engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    TextField("Spoken phrase, for example my GitHub", text: $newSmartLinkPhrase)
                        .textFieldStyle(.roundedBorder)
                    TextField("Destination URL (https://…)", text: $newSmartLinkURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSmartLink)
                    HStack {
                        Spacer()
                        Button("Add Smart Link", action: addSmartLink)
                            .disabled(!smartLinks.canMutate || newSmartLinkPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSmartLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .disabled(!smartLinks.canMutate)

                if smartLinks.store.links.isEmpty {
                    Text("No smart links saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(smartLinks.store.links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Spoken phrase", text: smartLinkPhraseBinding(for: link))
                                .textFieldStyle(.roundedBorder)
                            TextField("Destination URL", text: smartLinkURLBinding(for: link))
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Spacer()
                                Button("Save") { saveSmartLink(link) }
                                    .disabled(!smartLinks.canMutate)
                                Button("Remove", role: .destructive) { removeSmartLink(link) }
                                    .disabled(!smartLinks.canMutate)
                            }
                        }
                    }
                }

                if let errorMessage = smartLinks.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var voiceActionsSettings: some View {
        GroupBox("Voice actions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("These shortcuts are separate from Dictation. Press a shortcut once to start recording; it keeps recording after you let go. Tap your Dictation hotkey (\(runtime.hotkey.selectedKeyName)) or press the same shortcut again to finish. While EchoFlow is running these chords belong to EchoFlow, so other apps no longer receive them; change a chord if you need it in another app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice Memo: \(runtime.hotkey.voiceMemoShortcut.displayLabel ?? "Key \\(runtime.hotkey.voiceMemoShortcut.keyCode)")")
                        Text("Saves one new Markdown note per recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyboardShortcutCaptureButton(title: "Change Voice Memo Hotkey…") { shortcut in
                        guard runtime.hotkey.chooseVoiceMemoShortcut(shortcut) else {
                            voiceActionShortcutError = "Choose a chord that differs from Dictation, Rewrite, and the other EchoFlow hotkeys."
                            return
                        }
                        voiceActionShortcutError = nil
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rewrite: \(runtime.hotkey.rewriteShortcut.displayLabel ?? "Key \\(runtime.hotkey.rewriteShortcut.keyCode)")")
                        Text("Select text, press the shortcut, and speak an editing instruction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyboardShortcutCaptureButton(title: "Change Rewrite Hotkey…") { shortcut in
                        guard runtime.hotkey.chooseRewriteShortcut(shortcut) else {
                            voiceActionShortcutError = "Choose a chord that differs from Dictation, Voice Memo, and the other EchoFlow hotkeys."
                            return
                        }
                        voiceActionShortcutError = nil
                    }
                }

                if let message = runtime.hotkey.voiceActionShortcutConflictMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let voiceActionShortcutError {
                    Label(voiceActionShortcutError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Voice memo folder")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Choose Folder…") {
                        runtime.voiceMemoDestination.chooseDirectory()
                    }
                }
                Text(runtime.voiceMemoDestination.selectedDirectoryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("EchoFlow saves a separate date-and-time-named .md file in this folder. It does not paste the memo into the frontmost app or add it to transcript history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage = runtime.voiceMemoDestination.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Text("Voice Rewrite uses Apple Intelligence on this Mac only. It reads only the selected text from eligible fields and replaces it only if the same app, field, selection, and range are still active. Secure fields and excluded apps are blocked. If the on-device model is unavailable or fails, the selection is left unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(runtime.voiceRewriteAvailabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var textCleanupSettings: some View {
        GroupBox("Text cleanup") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Remove filler words (um, uh, like)", isOn: Binding(
                    get: { textCleanup.settings.removeFillerWords },
                    set: { textCleanup.setRemoveFillerWords($0) }
                ))
                Toggle("Remove repeated false starts", isOn: Binding(
                    get: { textCleanup.settings.removeFalseStarts },
                    set: { textCleanup.setRemoveFalseStarts($0) }
                ))
                Toggle("Convert spoken numbers to digits", isOn: Binding(
                    get: { textCleanup.settings.convertSpokenNumbersToDigits },
                    set: { textCleanup.setConvertSpokenNumbers($0) }
                ))
                Text("These switches are off by default and use local text rules. “Like” is removed only in clear discourse-filler positions; words such as “I like this” are kept. Repeated words and phrases are treated as false starts when that option is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Use on-device Apple Intelligence cleanup", isOn: Binding(
                    get: { textCleanup.settings.aiCleanupEnabled },
                    set: { textCleanup.setAIEnabled($0) }
                ))
                Text("Optional grammar and punctuation cleanup runs through Apple's on-device Foundation Models framework. EchoFlow sends no transcript or audio to a server. If Apple Intelligence is unavailable, the request fails, or it takes over 3 seconds, EchoFlow inserts the original recognized text exactly, without applying these text rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(textCleanup.availabilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Style by app")
                        .font(.subheadline.weight(.semibold))
                    ForEach(textCleanup.settings.applicationProfiles.sorted { $0.displayName < $1.displayName }) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                Text(profile.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("\(profile.displayName) style", selection: Binding(
                                get: { profile.style },
                                set: { textCleanup.setStyle($0, for: profile) }
                            )) {
                                ForEach(AppTranscriptWritingStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            if !TranscriptTextCleanupSettings.defaultApplicationProfiles.contains(where: {
                                $0.bundleIdentifier.caseInsensitiveCompare(profile.bundleIdentifier) == .orderedSame
                            }) {
                                Button("Reset") {
                                    textCleanup.removeProfile(profile)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset \(profile.displayName) style to Clean")
                            }
                        }
                    }
                    Text("Messages defaults to Casual, Obsidian and Claude to Clean, and Terminal to No changes. No changes bypasses all Batch 2 processing for that app. Apps not listed default to Clean; add or adjust a style below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add Installed App…", action: chooseTextCleanupApplication)
                        .disabled(!textCleanup.canMutate)
                }

                if let errorMessage = textCleanup.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .disabled(!textCleanup.canMutate)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var recordingBehaviorSettings: some View {
        GroupBox("Recording behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show live words in the recording overlay", isOn: $showLiveWords)
                Toggle("Change the Dock icon while recording", isOn: $changeDockIconWhileRecording)
                Toggle("Play optional recording start/stop sounds", isOn: $playRecordingSounds)
                HStack {
                    Text("Sound volume \(Int((recordingSoundVolume * 100).rounded()))%")
                        .frame(width: 125, alignment: .leading)
                    Slider(value: $recordingSoundVolume, in: 0...1, step: 0.05)
                        .accessibilityLabel("Recording sound volume")
                        .disabled(!playRecordingSounds)
                }
                Toggle("Keep microphone on between recordings (instant-on)", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityHint("Unavailable in this build; EchoFlow never leaves the microphone active between recordings.")
                Text("These cues are off by default. The overlay can show only a recording indicator when live words are hidden; temporary audio is still deleted after transcription unless audio saving is enabled above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var recordingAudioSettings: some View {
        GroupBox("Media and output volume") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Pause Music and Spotify while recording", isOn: Binding(
                    get: { recordingAudioOptions.pauseSupportedPlayersWhenRecording },
                    set: { recordingAudioOptions.pauseSupportedPlayersWhenRecording = $0 }
                ))
                Toggle("Lower system output volume while recording", isOn: Binding(
                    get: { recordingAudioOptions.lowerOutputVolumeWhenRecording },
                    set: { recordingAudioOptions.lowerOutputVolumeWhenRecording = $0 }
                ))
                HStack {
                    Text("Reduce by \(Int(recordingAudioOptions.outputVolumeReductionPercent))%")
                        .frame(width: 115, alignment: .leading)
                    Slider(value: Binding(
                        get: { recordingAudioOptions.outputVolumeReductionPercent },
                        set: { recordingAudioOptions.outputVolumeReductionPercent = $0 }
                    ), in: 0...100, step: 5)
                    .disabled(!recordingAudioOptions.lowerOutputVolumeWhenRecording)
                }

                Text("Media controls are optional and may require macOS Automation permission. Only Music and Spotify are controlled; browser media is not. EchoFlow restores the saved output volume when recording ends. Instant-on microphone is unavailable in this build, so EchoFlow never leaves it active between sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recordingAudioOptions.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var microphoneSettings: some View {
        GroupBox("Microphones") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Input", selection: Binding(
                    get: { microphones.pickerSelection },
                    set: { microphones.setPickerSelection($0) }
                )) {
                    Text("Automatic (priority order)").tag(MicrophoneSettingsViewModel.automaticSelection)
                    ForEach(microphones.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

                HStack {
                    Text("Ready now: \(microphones.currentReadyDevice?.name ?? "No microphone ready")")
                        .font(.caption)
                        .foregroundStyle(microphones.currentReadyDevice == nil ? .red : .secondary)
                    Spacer()
                    Button("Refresh") { microphones.refreshDevices() }
                }

                if microphones.orderedDevices.isEmpty {
                    Text("Connect or enable a microphone to see it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(microphones.orderedDevices) { device in
                            let index = microphones.priorityDeviceIDs.firstIndex(of: device.id) ?? 0
                            HStack {
                                Text(device.name)
                                Spacer()
                                if device.id == microphones.currentReadyDevice?.id {
                                    Label("Ready", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                Button {
                                    microphones.movePriority(id: device.id, direction: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                .accessibilityLabel("Move \(device.name) up")
                                Button {
                                    microphones.movePriority(id: device.id, direction: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == microphones.orderedDevices.count - 1)
                                .accessibilityLabel("Move \(device.name) down")
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 190)
                }

                Text("Automatic follows this order and appends newly discovered microphones at the bottom. A directly selected device falls back safely if it is disconnected or disallowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if microphones.isLidClosed {
                    Label("Closed-lid mode is active; the built-in MacBook microphone is skipped.", systemImage: "laptopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = microphones.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { microphones.refreshDevices() }
    }

    private func addVocabularyTerm() {
        do {
            _ = try vocabulary.addTerm(newVocabularyTerm)
            newVocabularyTerm = ""
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func vocabularyBinding(for term: CustomVocabularyTerm) -> Binding<String> {
        Binding(
            get: { vocabularyDrafts[term.id] ?? term.term },
            set: { vocabularyDrafts[term.id] = $0 }
        )
    }

    private func saveVocabularyTerm(_ term: CustomVocabularyTerm) {
        guard let draft = vocabularyDrafts[term.id] else { return }
        do {
            _ = try vocabulary.editTerm(id: term.id, to: draft)
            vocabularyDrafts.removeValue(forKey: term.id)
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func removeVocabularyTerm(_ term: CustomVocabularyTerm) {
        do {
            _ = try vocabulary.removeTerm(id: term.id)
            vocabularyDrafts.removeValue(forKey: term.id)
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func addSmartLink() {
        do {
            _ = try smartLinks.add(phrase: newSmartLinkPhrase, destinationURL: newSmartLinkURL)
            newSmartLinkPhrase = ""
            newSmartLinkURL = ""
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func smartLinkPhraseBinding(for link: SmartLink) -> Binding<String> {
        Binding(
            get: { smartLinkPhraseDrafts[link.id] ?? link.phrase },
            set: { smartLinkPhraseDrafts[link.id] = $0 }
        )
    }

    private func smartLinkURLBinding(for link: SmartLink) -> Binding<String> {
        Binding(
            get: { smartLinkURLDrafts[link.id] ?? link.destinationURL },
            set: { smartLinkURLDrafts[link.id] = $0 }
        )
    }

    private func saveSmartLink(_ link: SmartLink) {
        let values = SmartLinkEditPolicy.values(
            existingPhrase: link.phrase,
            existingDestinationURL: link.destinationURL,
            phraseDraft: smartLinkPhraseDrafts[link.id],
            destinationURLDraft: smartLinkURLDrafts[link.id]
        )
        do {
            _ = try smartLinks.edit(id: link.id, phrase: values.phrase, destinationURL: values.destinationURL)
            smartLinkPhraseDrafts.removeValue(forKey: link.id)
            smartLinkURLDrafts.removeValue(forKey: link.id)
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func removeSmartLink(_ link: SmartLink) {
        do {
            _ = try smartLinks.remove(id: link.id)
            smartLinkPhraseDrafts.removeValue(forKey: link.id)
            smartLinkURLDrafts.removeValue(forKey: link.id)
        } catch {
            // The view model exposes a local, user-readable error message.
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<TranscriptHistorySettings, Value>) -> Binding<Value> {
        Binding(
            get: { history.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = history.settings
                updated[keyPath: keyPath] = newValue
                history.settings = updated
            }
        )
    }

    private func chooseArchiveDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Transcript Archive Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let current = history.archiveDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        history.archiveDirectoryPath = url.path
    }

    private func chooseTextCleanupApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Installed App for Text Cleanup"
        panel.prompt = "Add App"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        textCleanup.addApplication(at: url)
    }

    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Installed App to Exclude"
        panel.prompt = "Exclude App"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            excludedApps.addApplication(at: url)
        }
    }
}
