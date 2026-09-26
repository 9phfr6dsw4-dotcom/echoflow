import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class TranscriptHistoryViewModel {
    private(set) var records: [TranscriptRecord] = []
    var errorMessage: String?
    var settings: TranscriptHistorySettings {
        didSet {
            persistSettings()
            pruneAndRefresh()
        }
    }
    var archiveDirectoryPath: String? {
        didSet {
            if let archiveDirectoryPath {
                defaults.set(archiveDirectoryPath, forKey: Self.archiveDirectoryDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.archiveDirectoryDefaultsKey)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let applicationSupportDirectory: URL

    private static let settingsDefaultsKey = "EchoFlow.transcriptHistorySettings"
    private static let archiveDirectoryDefaultsKey = "EchoFlow.transcriptArchiveDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.applicationSupportDirectory = Self.resolveApplicationSupportDirectory()
        if let data = defaults.data(forKey: Self.settingsDefaultsKey),
           let saved = try? JSONDecoder().decode(TranscriptHistorySettings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = TranscriptHistorySettings()
        }
        self.archiveDirectoryPath = defaults.string(forKey: Self.archiveDirectoryDefaultsKey)
        refresh()
        pruneAndRefresh()
    }

    var todayRecords: [TranscriptRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return records.filter { $0.timestamp >= start }
    }

    var totalWordCount: Int {
        records.reduce(0) { $0 + Self.wordCount(in: $1.text) }
    }

    var todayWordCount: Int {
        todayRecords.reduce(0) { $0 + Self.wordCount(in: $1.text) }
    }

    var totalRecordedDuration: TimeInterval {
        records.reduce(0) { $0 + $1.duration }
    }

    /// Estimates typing time avoided against a 40-words-per-minute baseline, less dictation time.
    var estimatedTimeSaved: TimeInterval {
        max(0, Double(totalWordCount) / 40 * 60 - totalRecordedDuration)
    }

    var dailyStreak: Int {
        let calendar = Calendar.current
        let activeDays = Set(records.map { calendar.startOfDay(for: $0.timestamp) })
        var cursor = calendar.startOfDay(for: Date())
        if !activeDays.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var count = 0
        while activeDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    func saveTranscript(
        _ text: String,
        duration: TimeInterval,
        modelID: String,
        audioData: Data? = nil
    ) throws {
        let record = TranscriptRecord(text: text, duration: duration, modelID: modelID)
        let store = makeStore()
        let persistencePlan = TranscriptPersistencePlan(
            historyEnabled: settings.historyEnabled,
            archiveDirectorySelected: archiveDirectoryPath != nil
        )
        if persistencePlan.saveToLocalHistory {
            try store.save(record, audioData: audioData)
            _ = try store.prune()
        }
        if persistencePlan.writeMarkdownArchive, let archiveDirectoryPath {
            try store.archiveMarkdown(for: record, to: URL(fileURLWithPath: archiveDirectoryPath, isDirectory: true))
        }
        refresh()
    }

    func clearAll() throws {
        try makeStore().clearAll()
        errorMessage = nil
        refresh()
    }

    func updateTranscript(_ record: TranscriptRecord, text: String) throws {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            throw TranscriptHistoryEditError.emptyTranscript
        }
        guard records.contains(where: { $0.id == record.id }) else {
            throw TranscriptHistoryEditError.recordNotFound
        }
        let updatedRecord = TranscriptRecord(
            id: record.id,
            text: cleanedText,
            timestamp: record.timestamp,
            duration: record.duration,
            modelID: record.modelID
        )
        let store = makeStore()
        try store.save(updatedRecord)
        if let archiveDirectoryPath {
            _ = try store.archiveMarkdown(
                for: updatedRecord,
                to: URL(fileURLWithPath: archiveDirectoryPath, isDirectory: true)
            )
        }
        refresh()
    }

    func reload() {
        refresh()
    }

    private func makeStore() -> TranscriptHistoryStore {
        TranscriptHistoryStore(
            applicationSupportDirectory: applicationSupportDirectory,
            settings: settings
        )
    }

    private func refresh() {
        do {
            records = try makeStore().records().sorted { $0.timestamp > $1.timestamp }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pruneAndRefresh() {
        do {
            _ = try makeStore().prune()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistSettings() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsDefaultsKey)
        } catch {
            errorMessage = "Could not save transcript-history settings: \(error.localizedDescription)"
        }
    }

    private static func resolveApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

private enum TranscriptHistoryEditError: LocalizedError {
    case emptyTranscript
    case recordNotFound

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "A saved transcript cannot be replaced with empty text."
        case .recordNotFound:
            "This transcript is no longer in EchoFlow history."
        }
    }
}
