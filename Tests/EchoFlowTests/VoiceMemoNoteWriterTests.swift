import Foundation
import XCTest
@testable import EchoFlowCore

final class VoiceMemoNoteWriterTests: XCTestCase {
    func testWritesOneMarkdownFileWithLocalTimestampAndTranscript() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_790_409_600)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let url = try VoiceMemoNoteWriter().write(
            "Remember to call Alex.",
            to: folder,
            timestamp: timestamp,
            timeZone: timeZone
        )

        XCTAssertEqual(url.lastPathComponent, "Voice-Memo-2026-09-26_08-00-00.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Voice Memo — 2026-09-26 08:00:00\n\nRemember to call Alex.\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [url.lastPathComponent])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testRemovesInheritedReadableACLBeforePublishingMemo() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let aclSetup = try runProcess(
            executable: "/bin/chmod",
            arguments: ["+a", "everyone allow read,file_inherit", folder.path]
        )
        guard aclSetup.status == 0 else {
            throw XCTSkip("This test volume does not allow adding an inherited ACL.")
        }

        let probeURL = folder.appendingPathComponent("inherited-acl-probe")
        XCTAssertTrue(FileManager.default.createFile(atPath: probeURL.path, contents: Data()))
        let probeListing = try runProcess(executable: "/bin/ls", arguments: ["-le", probeURL.path])
        let inheritedReadACE = probeListing.output.split(whereSeparator: \.isNewline).contains { line in
            let normalized = line.lowercased()
            return normalized.contains("everyone")
                && normalized.contains("allow")
                && normalized.contains("read")
        }
        guard probeListing.status == 0, inheritedReadACE else {
            throw XCTSkip("This test volume does not inherit the configured readable ACL to new files.")
        }
        try FileManager.default.removeItem(at: probeURL)

        let url = try VoiceMemoNoteWriter().write("Private memo", to: folder)
        let listing = try runProcess(executable: "/bin/ls", arguments: ["-le", url.path])
        let retainedReadableEveryoneACE = listing.output.split(whereSeparator: \.isNewline).contains { line in
            let normalized = line.lowercased()
            return normalized.contains("everyone")
                && normalized.contains("allow")
                && normalized.contains("read")
        }
        XCTAssertEqual(listing.status, 0, listing.output)
        XCTAssertFalse(retainedReadableEveryoneACE, listing.output)
    }

    func testNeverOverwritesAnotherMemoWithTheSameTimestamp() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = Date(timeIntervalSince1970: 1_790_409_600)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let writer = VoiceMemoNoteWriter()

        let first = try writer.write("First memo", to: folder, timestamp: timestamp, timeZone: timeZone)
        let second = try writer.write("Second memo", to: folder, timestamp: timestamp, timeZone: timeZone)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8).contains("First memo"), true)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8).contains("Second memo"), true)
    }

    func testRejectsEmptyTranscriptAndMissingDestination() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("not-created", isDirectory: true)
        let writer = VoiceMemoNoteWriter()

        XCTAssertThrowsError(try writer.write(" \n ", to: folder))
        XCTAssertThrowsError(try writer.write("Memo", to: missing))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testEveryErrorHasAUserFacingDescription() throws {
        let folder = URL(fileURLWithPath: "/tmp/Voice Memos", isDirectory: true)
        let cases: [(VoiceMemoNoteWriterError, String)] = [
            (.emptyTranscript, "No speech was recognized, so no voice memo was saved."),
            (
                .destinationIsNotDirectory(folder),
                "The selected voice memo destination is not an existing folder: /tmp/Voice Memos"
            ),
            (
                .atomicPublishUnavailable(folder),
                "This folder's storage does not support safely publishing a complete memo without replacing an existing file: /tmp/Voice Memos. Choose another folder."
            ),
            (
                .fileWriteFailed("/tmp/Voice Memos/memo.md", EACCES),
                "Could not save the voice memo at /tmp/Voice Memos/memo.md: \(POSIXError(.EACCES).localizedDescription)"
            )
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
            XCTAssertEqual((error as Error).localizedDescription, expected)
        }
    }

    func testBookmarkStorePersistsAndResolvesTheChosenExistingFolder() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suiteName = "VoiceMemoFolderBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceMemoFolderBookmarkStore(defaults: defaults)

        try store.save(directory: folder)
        let resolved = try XCTUnwrap(VoiceMemoFolderBookmarkStore(defaults: defaults).resolveDirectory())

        XCTAssertEqual(resolved.standardizedFileURL, folder.standardizedFileURL)
    }

    func testBookmarkStoreRejectsAFileAsTheDestination() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("not-a-folder.txt")
        try Data("contents".utf8).write(to: file)
        let suiteName = "VoiceMemoFolderBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertThrowsError(try VoiceMemoFolderBookmarkStore(defaults: defaults).save(directory: file))
        XCTAssertNil(defaults.data(forKey: VoiceMemoFolderBookmarkStore.bookmarkDefaultsKey))
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
