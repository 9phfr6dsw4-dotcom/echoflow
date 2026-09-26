import Foundation

public enum TranscriptHistoryRetention: String, Codable, CaseIterable, Hashable, Sendable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case forever

    public var retentionDays: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .forever: return nil
        }
    }
}

public struct TranscriptHistorySettings: Codable, Equatable, Sendable {
    public var historyEnabled: Bool
    public var retention: TranscriptHistoryRetention
    public var saveAudio: Bool

    public init(
        historyEnabled: Bool = true,
        retention: TranscriptHistoryRetention = .thirtyDays,
        saveAudio: Bool = false
    ) {
        self.historyEnabled = historyEnabled
        self.retention = retention
        self.saveAudio = saveAudio
    }
}

public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let modelID: String

    public init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        duration: TimeInterval,
        modelID: String
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.modelID = modelID
    }
}

public enum TranscriptHistoryError: Error, LocalizedError, Sendable {
    case invalidRecord(String)
    case archiveDirectoryDoesNotExist

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason):
            return "Invalid transcript record: \(reason)"
        case .archiveDirectoryDoesNotExist:
            return "The Markdown archive destination must be an existing directory."
        }
    }
}

/// Stores local transcript records and explicitly associated audio below EchoFlow's
/// application-support subdirectory. It never recursively deletes that directory.
public final class TranscriptHistoryStore {
    public static let storageDirectoryName = "EchoFlowTranscriptHistory"

    private let storageDirectoryURL: URL
    private let recordsFileURL: URL
    private let settings: TranscriptHistorySettings
    private let fileManager: FileManager

    public init(
        applicationSupportDirectory: URL,
        settings: TranscriptHistorySettings = TranscriptHistorySettings(),
        fileManager: FileManager = .default
    ) {
        let directoryURL = applicationSupportDirectory
            .appendingPathComponent(Self.storageDirectoryName, isDirectory: true)
        self.storageDirectoryURL = directoryURL
        self.recordsFileURL = directoryURL.appendingPathComponent("transcripts.json", isDirectory: false)
        self.settings = settings
        self.fileManager = fileManager
    }

    /// Persists nothing when history is disabled. Audio is written only when both
    /// the setting is enabled and audio data is supplied.
    public func save(_ record: TranscriptRecord, audioData: Data? = nil) throws {
        guard settings.historyEnabled else { return }
        try Self.validate(record)

        var storedRecords = try records()
        let previousRecordExists = storedRecords.contains { $0.id == record.id }
        storedRecords.removeAll { $0.id == record.id }
        storedRecords.append(record)

        try writeRecords(storedRecords)
        if settings.saveAudio, let audioData {
            try audioData.write(to: audioURL(for: record.id), options: .atomic)
        } else if !settings.saveAudio, previousRecordExists {
            try removeAudio(for: record.id)
        }
    }

    /// Returns records in chronological order, oldest first.
    public func records() throws -> [TranscriptRecord] {
        guard fileManager.fileExists(atPath: recordsFileURL.path) else { return [] }
        let data = try Data(contentsOf: recordsFileURL)
        let storedRecords = try JSONDecoder().decode([TranscriptRecord].self, from: data)
        return Self.sorted(storedRecords)
    }

    /// Deletes records older than the configured retention window. The cutoff
    /// instant itself is retained. Learned-term files are outside this store's
    /// owned records and are never enumerated or removed.
    @discardableResult
    public func prune(now: Date = Date()) throws -> [TranscriptRecord] {
        guard let retentionDays = settings.retention.retentionDays else { return [] }
        let storedRecords = try records()
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        let removedRecords = storedRecords.filter { $0.timestamp < cutoff }
        guard !removedRecords.isEmpty else { return [] }

        let removedIDs = Set(removedRecords.map(\.id))
        let remainingRecords = storedRecords.filter { !removedIDs.contains($0.id) }
        for record in removedRecords {
            try removeAudio(for: record.id)
        }
        try writeRecords(remainingRecords)
        return removedRecords
    }

    /// Loads audio only for a record currently present in the transcript index.
    public func loadAudio(for recordID: UUID) throws -> Data? {
        guard try records().contains(where: { $0.id == recordID }) else { return nil }
        let url = audioURL(for: recordID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Removes the index and audio files associated with indexed records. Other
    /// files, including learned words, are intentionally left untouched.
    public func clearAll() throws {
        let storedRecords = try records()
        for record in storedRecords {
            try removeAudio(for: record.id)
        }
        if fileManager.fileExists(atPath: recordsFileURL.path) {
            try fileManager.removeItem(at: recordsFileURL)
        }
        guard fileManager.fileExists(atPath: storageDirectoryURL.path) else { return }
        let ownedFiles = try fileManager.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in ownedFiles where isEchoFlowAudioFile(url) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Writes a Markdown snapshot into a directory that already exists. A unique
    /// filename avoids overwriting an existing archive or other user file.
    @discardableResult
    public func archiveMarkdown(to directoryURL: URL) throws -> URL {
        try writeMarkdown(markdownArchive(for: records()), to: directoryURL)
    }

    /// Writes one transcript record as a separate Markdown archive file.
    @discardableResult
    public func archiveMarkdown(for record: TranscriptRecord, to directoryURL: URL) throws -> URL {
        try Self.validate(record)
        return try writeMarkdown(markdownArchive(for: [record]), to: directoryURL)
    }

    private func writeMarkdown(_ markdown: String, to directoryURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TranscriptHistoryError.archiveDirectoryDoesNotExist
        }

        var archiveURL: URL
        repeat {
            archiveURL = directoryURL.appendingPathComponent(
                "EchoFlow-Transcript-History-\(UUID().uuidString).md",
                isDirectory: false
            )
        } while fileManager.fileExists(atPath: archiveURL.path)
        try Data(markdown.utf8).write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    private func ensureStorageDirectoryExists() throws {
        try fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func writeRecords(_ records: [TranscriptRecord]) throws {
        try ensureStorageDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Self.sorted(records)).write(to: recordsFileURL, options: .atomic)
    }

    private func audioURL(for recordID: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("\(recordID.uuidString).audio", isDirectory: false)
    }

    private func removeAudio(for recordID: UUID) throws {
        let url = audioURL(for: recordID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func isEchoFlowAudioFile(_ url: URL) -> Bool {
        guard url.pathExtension == "audio" else { return false }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    private static func sorted(_ records: [TranscriptRecord]) -> [TranscriptRecord] {
        records.sorted { left, right in
            if left.timestamp != right.timestamp {
                return left.timestamp < right.timestamp
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private static func validate(_ record: TranscriptRecord) throws {
        guard record.duration.isFinite, record.duration >= 0 else {
            throw TranscriptHistoryError.invalidRecord("duration must be finite and nonnegative")
        }
        guard record.timestamp.timeIntervalSince1970.isFinite else {
            throw TranscriptHistoryError.invalidRecord("timestamp must be finite")
        }
        guard !record.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptHistoryError.invalidRecord("model identifier must not be empty")
        }
    }

    private func markdownArchive(for records: [TranscriptRecord]) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# EchoFlow Transcript Archive", ""]
        for record in Self.sorted(records) {
            lines.append("## \(formatter.string(from: record.timestamp))")
            lines.append("")
            lines.append("- Duration: \(record.duration) seconds")
            lines.append("- Model: \(record.modelID)")
            lines.append("")
            lines.append(record.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
