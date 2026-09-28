import EchoFlowCore
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @Environment(EchoFlowRuntime.self) private var runtime
    @State private var model = FileTranscriptionViewModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe a File")
                .font(.title2.bold())
            Text("Turn an audio or video file into text with your selected speech model. Everything stays on this Mac.")
                .foregroundStyle(.secondary)
            dropZone
            statusSection
            if !model.transcript.isEmpty {
                resultSection
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Drop an audio or video file here")
                .font(.headline)
            Text("MP3, WAV, M4A, AAC, FLAC, AIFF, CAF, MP4, MOV, M4V")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose File…") { isImporterPresented = true }
                .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            model.start(fileURL: url, runtime: runtime)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .preparingAudio(let fileName), .transcribing(let fileName):
            VStack(alignment: .leading, spacing: 8) {
                Text(fileName)
                    .font(.headline)
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
                Text("Dictation that uses Whisper waits until this file is finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let fileName):
            Label("Finished: \(fileName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(model.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            HStack {
                Button("Copy") { model.copyTranscript() }
                Button("Save as Text (.txt)…") { model.save(asSubtitles: false) }
                Button("Save as Subtitles (.srt)…") { model.save(asSubtitles: true) }
                    .disabled(!model.canExportSubtitles)
            }
            if !model.canExportSubtitles {
                Text("This transcript has no timing information, so subtitles aren't available for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let saveError = model.saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
