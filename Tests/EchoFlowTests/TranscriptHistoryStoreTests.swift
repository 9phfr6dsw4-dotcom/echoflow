import Foundation
import XCTest
@testable import EchoFlowCore

final class TranscriptHistoryStoreTests: XCTestCase {
    func testTranscriptRecordCodableRoundTripPreservesMetadata() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = TranscriptRecord(
            text: "A local transcript.",
            timestamp: timestamp,
            duration: 12.5,
            modelID: "apple-speech"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TranscriptRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.timestamp, timestamp)
        XCTAssertEqual(decoded.duration, 12.5)
        XCTAssertEqual(decoded.modelID, "apple-speech")
    }

    func testHistorySettingsDefaultToThirtyDaysAndDoNotSaveAudio() {
        let settings = TranscriptHistorySettings()

        XCTAssertTrue(settings.historyEnabled)
        XCTAssertEqual(settings.retention, .thirtyDays)
        XCTAssertFalse(settings.saveAudio)
        XCTAssertEqual(TranscriptHistoryRetention.allCases, [.sevenDays, .thirtyDays, .ninetyDays, .forever])
        XCTAssertEqual(TranscriptHistoryRetention.sevenDays.retentionDays, 7)
        XCTAssertEqual(TranscriptHistoryRetention.thirtyDays.retentionDays, 30)
        XCTAssertEqual(TranscriptHistoryRetention.ninetyDays.retentionDays, 90)
        XCTAssertNil(TranscriptHistoryRetention.forever.retentionDays)
    }

    func testSavingByDefaultStoresTranscriptWithoutAudio() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptHistoryStore(applicationSupportDirectory: root)
        let record = makeRecord(text: "Keep this local.")

        try store.save(record, audioData: Data([1, 2, 3]))

        XCTAssertEqual(try store.records(), [record])
        XCTAssertNil(try store.loadAudio(for: record.id))
    }

    func testDisabledHistoryDoesNotPersistTranscriptOrAudio() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = TranscriptHistorySettings(historyEnabled: false, retention: .sevenDays, saveAudio: true)
        let store = TranscriptHistoryStore(applicationSupportDirectory: root, settings: settings)
        let record = makeRecord(text: "Do not persist.")

        try store.save(record, audioData: Data([4, 5, 6]))

        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertNil(try store.loadAudio(for: record.id))
    }

    func testPruningRemovesOnlyRecordsOlderThanRetentionAndKeepsLearnedTerms() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let learnedTermsURL = root.appendingPathComponent("learned-words.json")
        let learnedTerms = Data("[\"Hermes\"]".utf8)
        try learnedTerms.write(to: learnedTermsURL)

        let settings = TranscriptHistorySettings(saveAudio: true)
        let store = TranscriptHistoryStore(applicationSupportDirectory: root, settings: settings)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expired = makeRecord(timestamp: now.addingTimeInterval(-30 * 24 * 60 * 60 - 1))
        let boundary = makeRecord(timestamp: now.addingTimeInterval(-30 * 24 * 60 * 60))
        let recent = makeRecord(timestamp: now.addingTimeInterval(-1))
        for record in [expired, boundary, recent] {
            try store.save(record, audioData: Data([UInt8(record.id.uuidString.utf8.first!)]))
        }

        let removed = try store.prune(now: now)

        XCTAssertEqual(removed.map(\.id), [expired.id])
        XCTAssertEqual(Set(try store.records().map(\.id)), Set([boundary.id, recent.id]))
        XCTAssertNil(try store.loadAudio(for: expired.id))
        XCTAssertEqual(try store.loadAudio(for: boundary.id), Data([UInt8(boundary.id.uuidString.utf8.first!)]))
        XCTAssertEqual(try Data(contentsOf: learnedTermsURL), learnedTerms)
    }

    func testForeverRetentionDoesNotPruneOldRecords() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = TranscriptHistorySettings(retention: .forever)
        let store = TranscriptHistoryStore(applicationSupportDirectory: root, settings: settings)
        let oldRecord = makeRecord(timestamp: Date(timeIntervalSince1970: 0))
        try store.save(oldRecord)

        XCTAssertTrue(try store.prune(now: Date(timeIntervalSince1970: 2_000_000_000)).isEmpty)
        XCTAssertEqual(try store.records(), [oldRecord])
    }

    func testClearAllRemovesOwnedTranscriptAndAudioWithoutDeletingOtherFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptHistoryStore(
            applicationSupportDirectory: root,
            settings: TranscriptHistorySettings(saveAudio: true)
        )
        let record = makeRecord(text: "Clear me.")
        try store.save(record, audioData: Data([7, 8, 9]))

        let learnedTermsURL = root.appendingPathComponent("learned-words.json")
        let learnedTerms = Data("[\"EchoFlow\"]".utf8)
        try learnedTerms.write(to: learnedTermsURL)
        let unrelatedURL = root
            .appendingPathComponent(TranscriptHistoryStore.storageDirectoryName, isDirectory: true)
            .appendingPathComponent("user-owned-file.txt")
        try Data("leave this alone".utf8).write(to: unrelatedURL)

        try store.clearAll()

        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertNil(try store.loadAudio(for: record.id))
        XCTAssertEqual(try Data(contentsOf: learnedTermsURL), learnedTerms)
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), Data("leave this alone".utf8))
    }

    func testClearAllAlsoRemovesOrphanedEchoFlowAudioButLeavesOtherFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptHistoryStore(
            applicationSupportDirectory: root,
            settings: TranscriptHistorySettings(saveAudio: true)
        )
        let record = makeRecord(text: "Indexed audio")
        try store.save(record, audioData: Data([1, 2, 3]))

        let ownedDirectory = root.appendingPathComponent(
            TranscriptHistoryStore.storageDirectoryName,
            isDirectory: true
        )
        let orphanID = UUID()
        let orphanAudioURL = ownedDirectory.appendingPathComponent("\(orphanID.uuidString).audio")
        try Data([4, 5, 6]).write(to: orphanAudioURL)
        let unrelatedURL = ownedDirectory.appendingPathComponent("leave-me.txt")
        try Data("unrelated".utf8).write(to: unrelatedURL)

        try store.clearAll()

        XCTAssertNil(try store.loadAudio(for: record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAudioURL.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), Data("unrelated".utf8))
        XCTAssertTrue(try store.records().isEmpty)
    }

    func testSavingAnEditedTranscriptReplacesTextWithoutChangingRecordIdentityOrMetadata() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptHistoryStore(applicationSupportDirectory: root)
        let original = makeRecord(text: "Kubernets is useful.")
        let corrected = TranscriptRecord(
            id: original.id,
            text: "Kubernetes is useful.",
            timestamp: original.timestamp,
            duration: original.duration,
            modelID: original.modelID
        )
        try store.save(original)

        try store.save(corrected)

        XCTAssertEqual(try store.records(), [corrected])
        XCTAssertEqual(try store.records().count, 1)
        XCTAssertEqual(try store.records().first?.id, original.id)
        XCTAssertEqual(try store.records().first?.timestamp, original.timestamp)
        XCTAssertEqual(try store.records().first?.duration, original.duration)
        XCTAssertEqual(try store.records().first?.modelID, original.modelID)
    }

    func testMarkdownArchiveWritesTranscriptAndMetadataToExistingChosenDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDirectory = root.appendingPathComponent("chosen-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let store = TranscriptHistoryStore(applicationSupportDirectory: root)
        let record = makeRecord(text: "Archive this sentence.", modelID: "whisper-local")
        try store.save(record)

        let archiveURL = try store.archiveMarkdown(to: archiveDirectory)
        let markdown = try String(contentsOf: archiveURL, encoding: .utf8)

        XCTAssertTrue(archiveURL.deletingLastPathComponent().standardizedFileURL == archiveDirectory.standardizedFileURL)
        XCTAssertTrue(markdown.contains("Archive this sentence."))
        XCTAssertTrue(markdown.contains("whisper-local"))
        XCTAssertTrue(markdown.contains("12.5"))
        XCTAssertTrue(markdown.contains("EchoFlow Transcript Archive"))
    }

    func testMarkdownArchiveRejectsDirectoryThatDoesNotAlreadyExist() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptHistoryStore(applicationSupportDirectory: root)
        let missingDirectory = root.appendingPathComponent("not-created", isDirectory: true)

        XCTAssertThrowsError(try store.archiveMarkdown(to: missingDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
    }

    func testPerTranscriptMarkdownArchiveContainsOnlySelectedRecord() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDirectory = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let store = TranscriptHistoryStore(applicationSupportDirectory: root)
        try store.save(makeRecord(text: "First transcript"))
        let selected = makeRecord(text: "Selected transcript")
        try store.save(selected)

        let archiveURL = try store.archiveMarkdown(for: selected, to: archiveDirectory)
        let markdown = try String(contentsOf: archiveURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Selected transcript"))
        XCTAssertFalse(markdown.contains("First transcript"))
    }

    func testPerTranscriptMarkdownArchiveWorksWhenLocalHistoryIsDisabled() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDirectory = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let store = TranscriptHistoryStore(
            applicationSupportDirectory: root,
            settings: TranscriptHistorySettings(historyEnabled: false)
        )
        let record = makeRecord(text: "Archive without local history.")

        let archiveURL = try store.archiveMarkdown(for: record, to: archiveDirectory)
        let markdown = try String(contentsOf: archiveURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Archive without local history."))
        XCTAssertTrue(try store.records().isEmpty)
    }

    private func makeRecord(
        id: UUID = UUID(),
        text: String = "Transcript",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        duration: TimeInterval = 12.5,
        modelID: String = "apple-speech"
    ) -> TranscriptRecord {
        TranscriptRecord(id: id, text: text, timestamp: timestamp, duration: duration, modelID: modelID)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowTranscriptHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
