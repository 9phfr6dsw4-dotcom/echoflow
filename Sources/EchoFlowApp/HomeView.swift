import AppKit
import EchoFlowCore
import SwiftUI

struct HomeView: View {
    @Environment(EchoFlowRuntime.self) private var runtime
    @AppStorage("EchoFlow.hasSeenLaunchAtLoginOption") private var hasSeenLaunchAtLoginOption = false

    private var history: TranscriptHistoryViewModel { runtime.history }
    private var launchAtLogin: LaunchAtLoginController { runtime.launchAtLogin }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EchoFlow")
                        .font(.largeTitle.weight(.semibold))
                    Text("Private, on-device dictation")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if !hasSeenLaunchAtLoginOption {
                    launchAtLoginWelcome
                }
                SpeechDictationPanel()
                stats
                todaySection
            }
            .padding(28)
            // Fill the window at any size, including full screen.
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 580)
    }

    private var launchAtLoginWelcome: some View {
        GroupBox("A small startup choice") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch EchoFlow at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Text("This is on by default. macOS may ask you to approve EchoFlow in Login Items; you can change this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = launchAtLogin.statusMessage {
                    HStack {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
                HStack {
                    Spacer()
                    Button("Continue") { hasSeenLaunchAtLoginOption = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
            metric("Words", value: history.totalWordCount.formatted(), symbol: "text.word.spacing")
            metric("Sessions", value: history.records.count.formatted(), symbol: "waveform")
            metric("Today", value: history.todayWordCount.formatted(), symbol: "calendar")
            metric("Time saved*", value: formattedTime(history.estimatedTimeSaved), symbol: "clock")
            metric("Daily streak", value: "\(history.dailyStreak) days", symbol: "flame")
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today's transcripts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("*Estimated against typing at 40 words per minute")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = history.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if history.todayRecords.isEmpty {
                ContentUnavailableView(
                    history.settings.historyEnabled ? "No transcripts today" : "Transcript history is off",
                    systemImage: "text.bubble",
                    description: Text(history.settings.historyEnabled
                        ? "Your saved transcripts will appear here."
                        : "Turn on local transcript history in Settings to save transcripts.")
                )
                .frame(minHeight: 170)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(history.todayRecords) { record in
                        transcriptCard(record)
                    }
                }
            }
        }
    }

    private func transcriptCard(_ record: TranscriptRecord) -> some View {
        TranscriptCardView(record: record) { correctedText in
            try history.updateTranscript(record, text: correctedText)
            runtime.localLearning.observeTranscriptCorrection(
                original: record.text,
                corrected: correctedText
            )
        }
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

private struct TranscriptCardView: View {
    let record: TranscriptRecord
    let onSave: (String) throws -> Void

    @State private var isEditing = false
    @State private var editedText: String
    @State private var errorMessage: String?

    init(record: TranscriptRecord, onSave: @escaping (String) throws -> Void) {
        self.record = record
        self.onSave = onSave
        _editedText = State(initialValue: record.text)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(wordCount(isEditing ? editedText : record.text)) words")
                    Text("·")
                    Text(formattedTime(record.duration))
                    Spacer()
                    if isEditing {
                        Button("Cancel") {
                            editedText = record.text
                            errorMessage = nil
                            isEditing = false
                        }
                        Button("Save correction") { saveCorrection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        Button("Edit") {
                            editedText = record.text
                            isEditing = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isEditing {
                    TextEditor(text: $editedText)
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(record.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 3)
        }
        .onChange(of: record.text) { _, newValue in
            if !isEditing { editedText = newValue }
        }
    }

    private func saveCorrection() {
        do {
            try onSave(editedText)
            errorMessage = nil
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
