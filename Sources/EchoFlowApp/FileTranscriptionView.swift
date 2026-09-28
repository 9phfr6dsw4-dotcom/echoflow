import EchoFlowCore
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @Environment(EchoFlowRuntime.self) private var runtime
    @State private var model = FileTranscriptionViewModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var pendingDeletion: FileTranscriptDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcribe File")
                        .font(.largeTitle.weight(.semibold))
                    Text("Turn an audio or video file into a transcript with timestamps and, if you like, speaker labels. Everything stays on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                fileSection
                optionsSection
                if model.isBusy || isFailed {
                    progressSection
                }
                if let document = model.document {
                    transcriptSection(document)
                }
                recentSection

                Label("Files are transcribed on this Mac. Speaker detection downloads its model once, the first time you use it; your audio and transcripts never leave this Mac.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.start(fileURL: url, runtime: runtime)
                }
            case .failure(let error):
                model.showError(error.localizedDescription)
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Transcript", role: .destructive) {
                if let pendingDeletion { model.delete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("\(pendingDeletion?.displayTitle ?? "This transcript") will be removed from Recent files. Files you saved elsewhere are kept.")
        }
        .onAppear { model.refresh(runtime: runtime) }
        .frame(minWidth: 760, minHeight: 580)
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    // MARK: File

    private var fileSection: some View {
        GroupBox("File") {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                Text("Drop an audio or video file here")
                    .font(.headline)
                Text("MP3, WAV, M4A, AAC, FLAC, AIFF, CAF, MP4, MOV, M4V")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose File…") { isImporterPresented = true }
                    .disabled(model.isBusy)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6])
                    )
            )
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !model.isBusy else { return false }
                model.start(fileURL: url, runtime: runtime)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        GroupBox("Options") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Title", text: $model.title, prompt: Text("Title (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                    Text("Shown at the top of the transcript and every saved file. Leave it empty to use the file name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Engine", selection: $model.engineID) {
                        ForEach(model.availableEngines(runtime: runtime)) { engine in
                            Text(engine.id == ModelSelection.parakeetEngineID ? "\(engine.displayName) (recommended)" : engine.displayName)
                                .tag(engine.id)
                        }
                    }
                    .fixedSize()
                    .disabled(model.isBusy)
                    Text(engineNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    recommendation
                }

                Divider()

                cleanupOptions

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        Toggle("Detect speakers", isOn: $model.detectSpeakers)
                            .disabled(model.isBusy)
                        if model.detectSpeakers {
                            Picker("Speakers", selection: $model.speakerCount) {
                                Text("Automatic").tag(0)
                                ForEach(2...6, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .fixedSize()
                            .disabled(model.isBusy)
                        }
                    }
                    Text("Labels who is talking (Speaker 1, Speaker 2…) with a timestamp at each change; you can rename speakers when it finishes. Adds some time. If you know how many people speak, choosing the number helps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var engineNote: String {
        switch model.engineID {
        case ModelSelection.parakeetEngineID:
            return "Fastest, and the most word-for-word."
        case ModelSelection.appleSpeechEngineID:
            return "Fast. Can miss unusual names."
        case FileTranscriptionViewModel.whisperEngineID:
            return "By far the slowest engine: a long file can take several minutes. It tidies up false starts on its own, but can skip or add a few words. Dictation that uses Whisper waits until the file is done."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var recommendation: some View {
        let cleanup = model.fileCleanup
        if model.engineID == ModelSelection.parakeetEngineID && cleanup.removeFillerWords
            && cleanup.removeFalseStarts && cleanup.convertSpokenNumbersToDigits {
            Label("Recommended setup: Parakeet, with filler words, false starts and numbers to digits turned on.", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Recommended: Parakeet, with Remove filler words, Remove repeated false starts and Convert spoken numbers to digits turned on below.", systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cleanupOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text cleanup for transcribed files")
                .font(.subheadline.weight(.semibold))
            Toggle("Remove filler words (um, uh)", isOn: $model.fileCleanup.removeFillerWords)
            Toggle("Remove repeated false starts (\u{201C}with, with\u{201D})", isOn: $model.fileCleanup.removeFalseStarts)
            Toggle("Convert spoken numbers to digits", isOn: $model.fileCleanup.convertSpokenNumbersToDigits)
            Text("Years and numbers of 10 or more become digits (1789, 600,000); one to nine stay as words.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            Toggle("Polish punctuation with Apple Intelligence", isOn: $model.fileCleanup.aiCleanupEnabled)
                .disabled(model.polishUnavailableMessage != nil)
            Text("Fixes punctuation, capitals and small slips, one paragraph at a time, on this Mac. This adds time (often a minute or two for a long file) and may occasionally change the wording; a paragraph it changes too much is kept as transcribed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            if let message = model.polishUnavailableMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
            Label("These switches only affect Transcribe File. Dictation uses Settings → Text cleanup, and neither changes the other.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy)
    }

    // MARK: Progress

    private var progressSection: some View {
        GroupBox("Progress") {
            VStack(alignment: .leading, spacing: 10) {
                if let fileName = model.busyFileName {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fileName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("Engine: \(model.runningEngineName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    HStack {
                        Text(model.progressText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancel() }
                    }
                    if model.runningEngineIsWhisper {
                        Text("Whisper is by far the slowest engine, so a long file can take several minutes. Dictation that uses Whisper waits until this file is done.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if case .failed(let message) = model.phase {
                    HStack(alignment: .firstTextBaseline) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { model.dismissError() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Transcript

    private func transcriptSection(_ document: FileTranscriptDocument) -> some View {
        GroupBox("Transcript") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayTitle)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(model.detailsLine(for: document))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if document.hasSpeakers {
                    speakerNames(document)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                            VStack(alignment: .leading, spacing: 4) {
                                if document.hasTimings || block.speakerID != nil {
                                    HStack(spacing: 8) {
                                        if document.hasTimings {
                                            Text(FileTranscriptExporter.timestamp(block.start))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        if let name = document.speakerName(for: block.speakerID) {
                                            Text(name)
                                                .font(.subheadline.weight(.semibold))
                                        }
                                    }
                                }
                                Text(block.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(height: 420)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 10) {
                    Button("Copy") { model.copyTranscript() }
                    Menu("Save As…") {
                        ForEach(FileTranscriptionViewModel.ExportFormat.allCases) { format in
                            Button(format.menuTitle) { model.export(format) }
                                .disabled(format == .subtitles && document.subtitleSRT.isEmpty)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button {
                        model.clear()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .disabled(model.isBusy)
                }

                if let polishNote = model.polishNote {
                    Label(polishNote, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if document.subtitleSRT.isEmpty {
                    Text("This transcript has no timing information, so subtitles aren't available for it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let saveError = model.saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func speakerNames(_ document: FileTranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.subheadline.weight(.semibold))
            ForEach(document.speakerIDs, id: \.self) { speakerID in
                HStack(spacing: 10) {
                    Text(document.defaultSpeakerName(for: speakerID))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    TextField(
                        document.defaultSpeakerName(for: speakerID),
                        text: Binding(
                            get: { model.speakerNameText(for: speakerID) },
                            set: { model.rename(speakerID: speakerID, to: $0) }
                        ),
                        prompt: Text("Name")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                }
            }
            Text("Type a name to use it everywhere in this transcript, including saved files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Recent files

    private var recentSection: some View {
        GroupBox("Recent files") {
            VStack(alignment: .leading, spacing: 10) {
                if !model.historyEnabled {
                    Text("Transcript history is off in Settings, so file transcripts aren't kept here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.recentDocuments.isEmpty {
                    Text("Transcribed files appear here so you can reopen or re-save them later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.recentDocuments) { saved in
                            recentRow(saved)
                            if saved.id != model.recentDocuments.last?.id {
                                Divider()
                            }
                        }
                    }
                    Text("Kept for \(retentionText), like your other transcripts (Settings → Transcript history). Clear All Data there also removes them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func recentRow(_ saved: FileTranscriptDocument) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.displayTitle)
                    .fontWeight(saved.id == model.document?.id ? .semibold : .regular)
                    .lineLimit(1)
                Text(model.detailsLine(for: saved))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Open") { model.open(saved) }
                .disabled(model.isBusy || saved.id == model.document?.id)
            Button(role: .destructive) {
                pendingDeletion = saved
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete from Recent files")
            .disabled(model.isBusy)
        }
        .padding(.vertical, 7)
    }

    private var retentionText: String {
        switch model.retention {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .forever: "as long as you keep them"
        }
    }
}
