import AppKit
import EchoFlowCore
import SwiftUI

struct SpeechDictationPanel: View {
    @Environment(EchoFlowRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("EchoFlow.showLiveWords") private var showLiveWords = true
    @AppStorage("EchoFlow.autoSend") private var autoSend = false
    @State private var shortcutCaptureError: String?
    @State private var showingInsertionDebugInfo = false

    private var dictation: SpeechDictationViewModel { runtime.dictation }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: dictation.isRecording ? "waveform.circle.fill" : "waveform")
                        .font(.title2)
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(dictation.microphoneName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actionButton
                }

                Text("Apple Speech checks whether its system assets are installed. Choose Prepare Apple Speech to install missing assets. Parakeet and Whisper are downloaded only when you explicitly choose them in Speech Models. Live words are available with Apple Speech; temporary audio is deleted after transcription.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                hotkeySettings

                if dictation.isCheckingAssets {
                    ProgressView("Checking Apple Speech assets…")
                } else if dictation.isPreparingAssets {
                    ProgressView("Preparing Apple Speech assets…")
                } else if dictation.isTranscribing {
                    ProgressView("Transcribing locally…")
                }

                if !dictation.transcript.isEmpty {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("Transcript")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dictation.transcript, forType: .string)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(dictation.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let deliveryMessage = runtime.deliveryMessage {
                    Label(deliveryMessage, systemImage: "text.bubble")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let deliveryDebugInfo = runtime.deliveryDebugInfo {
                    DisclosureGroup("Insertion debug info", isExpanded: $showingInsertionDebugInfo) {
                        Text(deliveryDebugInfo)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }

                if let errorMessage = dictation.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } label: {
            Label("Dictation", systemImage: "mic")
        }
        .onAppear {
            runtime.overlayModel.showLiveWords = showLiveWords
            runtime.hotkey.refreshPermission()
        }
        .onChange(of: showLiveWords) { _, isVisible in
            runtime.overlayModel.showLiveWords = isVisible
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                runtime.hotkey.refreshPermission()
            }
        }
    }

    private var hotkeySettings: some View {
        GroupBox("Global hotkey") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Picker("Gesture", selection: Binding(
                        get: { runtime.hotkey.selectedMode },
                        set: { runtime.hotkey.chooseMode($0) }
                    )) {
                        Text("Tap to toggle").tag(ModifierHotkeyMode.tapToToggle)
                        Text("Hold to talk").tag(ModifierHotkeyMode.holdToTalk)
                    }
                    .frame(width: 220)

                    Picker("Primary key", selection: Binding(
                        get: { runtime.hotkey.selectedKeyCode },
                        set: { runtime.hotkey.chooseKey(keyCode: $0) }
                    )) {
                        Text("Left Control").tag(UInt16(59))
                        Text("Right Option").tag(UInt16(61))
                        Text("Fn / Globe").tag(UInt16(63))
                        if runtime.hotkey.selectedShortcut != nil {
                            Text("Custom — \(runtime.hotkey.selectedKeyName)")
                                .tag(runtime.hotkey.selectedKeyCode)
                        }
                    }
                    .frame(width: 245)

                    if runtime.hotkey.hasAccessibilityPermission {
                        Button(runtime.hotkey.isEnabled ? "Disable Hotkey" : "Enable Hotkey") {
                            if runtime.hotkey.isEnabled {
                                runtime.hotkey.disable()
                            } else {
                                runtime.hotkey.enable()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Request Accessibility Access") {
                            runtime.hotkey.requestEnable()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack(spacing: 12) {
                    KeyboardShortcutCaptureButton(title: "Set Custom Primary…") { shortcut in
                        guard runtime.hotkey.chooseCustomShortcut(shortcut) else {
                            shortcutCaptureError = "That key cannot be used as a custom hotkey."
                            return
                        }
                        shortcutCaptureError = nil
                    }

                    if let backup = runtime.hotkey.backupShortcut {
                        Text("Backup: \(backup.displayLabel ?? "Key \(backup.keyCode)")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        KeyboardShortcutCaptureButton(title: "Change Backup…") { shortcut in
                            guard runtime.hotkey.chooseBackupShortcut(shortcut) else {
                                shortcutCaptureError = "The backup hotkey must be a valid, distinct key chord."
                                return
                            }
                            shortcutCaptureError = nil
                        }
                        Button("Remove Backup") {
                            _ = runtime.hotkey.chooseBackupShortcut(nil)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        KeyboardShortcutCaptureButton(title: "Add Backup…") { shortcut in
                            guard runtime.hotkey.chooseBackupShortcut(shortcut) else {
                                shortcutCaptureError = "The backup hotkey must be a valid, distinct key chord."
                                return
                            }
                            shortcutCaptureError = nil
                        }
                    }
                }

                if let shortcutCaptureError {
                    Text(shortcutCaptureError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text(runtime.hotkey.statusMessage)
                    .font(.caption)
                    .foregroundStyle(runtime.hotkey.hasAccessibilityPermission ? Color.gray : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Toggle("Show live words in the recording overlay", isOn: $showLiveWords)
                    .font(.caption)
                Text("Dictation and Voice Rewrite insert text without using the clipboard. Use Copy only when you explicitly want to copy a transcript.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Press Return after inserting text", isOn: $autoSend)
                    .font(.caption)
                if autoSend {
                    Text("Auto-send can submit a message or form in the target app. Return is sent only when Accessibility confirms the insertion; the keyboard-event fallback never submits automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var actionButton: some View {
        Group {
            if dictation.isRecording {
                Button(role: .destructive) {
                    Task { await runtime.toggleRecording() }
                } label: {
                    Label("Stop and Transcribe", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if needsApplePreparation {
                Button {
                    Task {
                        await dictation.prepareAppleSpeech(
                            localeIdentifier: runtime.preferredTranscriptionLanguageIdentifier
                        )
                    }
                } label: {
                    Label(
                        dictation.isCheckingAssets
                            ? "Checking Apple Speech…"
                            : dictation.isPreparingAssets
                                ? "Preparing Apple Speech…"
                                : "Prepare Apple Speech",
                        systemImage: dictation.isCheckingAssets ? "magnifyingglass" : "arrow.down.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(dictation.isCheckingAssets || dictation.isPreparingAssets || dictation.isTranscribing)
            } else {
                Button {
                    Task { await runtime.startRecording() }
                } label: {
                    Label("Start Dictation", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(dictation.isPreparingAssets || dictation.isTranscribing || !canStartRecording)
            }
        }
    }

    private var selectedBackend: TranscriptionBackend? {
        guard let catalog = runtime.modelLibrary.catalog else { return nil }
        return TranscriptionBackend.resolve(
            engineID: runtime.modelLibrary.selectedEngineID,
            catalog: catalog,
            installedDownloadIDs: runtime.modelLibrary.installedDownloadIDs
        )
    }

    private var needsApplePreparation: Bool {
        selectedBackend == .appleSpeech && !dictation.isAppleSpeechPrepared(
            for: runtime.preferredTranscriptionLanguageIdentifier
        )
    }

    private var canStartRecording: Bool {
        switch selectedBackend {
        case .some(.appleSpeech):
            dictation.isAppleSpeechPrepared(for: runtime.preferredTranscriptionLanguageIdentifier)
        case .some(.parakeetV3), .some(.whisperLargeV3Turbo):
            runtime.modelLibrary.installedModelDirectory(for: runtime.modelLibrary.selectedEngineID) != nil
        case .some(.unavailable), .none:
            false
        }
    }

    private var statusTitle: String {
        if dictation.isCheckingAssets { return "Checking Apple Speech assets" }
        if dictation.isPreparingAssets { return "Preparing Apple Speech assets" }
        if dictation.isRecording { return "Listening" }
        if dictation.isTranscribing { return "Finishing transcription" }
        if canStartRecording { return "Ready" }
        if needsApplePreparation { return "Apple Speech setup required" }
        return "Selected model unavailable"
    }
}
