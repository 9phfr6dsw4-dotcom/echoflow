import Foundation
import XCTest
@testable import EchoFlowCore

final class LocalLearningFileStoreTests: XCTestCase {
    func testLoadingAbsentFileReturnsDefaultStore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing/local-learning.json")

        XCTAssertEqual(try LocalLearningFileStore.load(from: url), LocalLearningStore())
    }

    func testSavingCreatesParentDirectoryAndRoundTripsLearningState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root
            .appendingPathComponent("nested/storage", isDirectory: true)
            .appendingPathComponent("local-learning.json")
        var store = LocalLearningStore()
        for _ in 0..<3 {
            _ = store.observeCorrection(original: "Kubernets", replacement: "Kubernetes")
        }
        XCTAssertTrue(store.setPinned(true, for: "Kubernetes"))

        try LocalLearningFileStore.save(store, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertEqual(try LocalLearningFileStore.load(from: url), store)
    }

    func testClearingTranscriptHistoryDoesNotRemoveSeparatelySavedLearningState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let learningURL = root
            .appendingPathComponent("local-learning", isDirectory: true)
            .appendingPathComponent("store.json")
        let historyStore = TranscriptHistoryStore(applicationSupportDirectory: root)
        var learningStore = LocalLearningStore()
        for _ in 0..<3 {
            _ = learningStore.observeCorrection(original: "Kubernets", replacement: "Kubernetes")
        }
        try LocalLearningFileStore.save(learningStore, to: learningURL)
        try historyStore.save(
            TranscriptRecord(text: "Unrelated transcript", duration: 1, modelID: "apple-speech")
        )

        try historyStore.clearAll()

        XCTAssertTrue(try historyStore.records().isEmpty)
        XCTAssertEqual(try LocalLearningFileStore.load(from: learningURL), learningStore)
    }

    func testLoadingCorruptJSONThrowsInsteadOfResettingExistingData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local-learning.json")
        let corruptJSON = Data("{not valid JSON".utf8)
        try corruptJSON.write(to: url)

        XCTAssertThrowsError(try LocalLearningFileStore.load(from: url)) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(try Data(contentsOf: url), corruptJSON)
    }

    func testLoadingDirectoryReportsReadError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try LocalLearningFileStore.load(from: root))
    }

    func testSavingWhenParentPathIsAFileReportsWriteError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentFile = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: parentFile)
        let destination = parentFile.appendingPathComponent("local-learning.json")

        XCTAssertThrowsError(try LocalLearningFileStore.save(LocalLearningStore(), to: destination))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowLocalLearningFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
