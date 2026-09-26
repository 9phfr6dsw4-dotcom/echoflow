import Foundation
import XCTest
@testable import EchoFlowCore

final class WhisperModelCacheTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowWhisperCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(
            to: directory.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin")
        )
        return directory
    }

    func testRepeatedDictationsReuseOneModelButKeepPerCallOptions() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let first = try await cache.withModel(at: directory, load: load) { model in "\(model):en" }
        let second = try await cache.withModel(at: directory, load: load) { model in "\(model):fr" }
        XCTAssertEqual(first, "1:en")
        XCTAssertEqual(second, "1:fr")
        let loadCount = await loads.value
        XCTAssertEqual(loadCount, 1)
    }

    func testSamePathNestedAssetReplacementInvalidatesCachedModel() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let first = try await cache.withModel(at: directory, load: load) { $0 }
        let weight = directory.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin")
        try FileManager.default.removeItem(at: weight)
        try Data("later".utf8).write(to: weight) // same path and byte count; different inode
        let second = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
    }

    func testSameSizeInPlaceWriteWithRestoredModificationDateInvalidatesCache() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let weight = directory.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin")
        let oldDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: weight.path)[.modificationDate] as? Date
        )
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let before = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(before, 1)

        let handle = try FileHandle(forWritingTo: weight)
        try handle.write(contentsOf: Data("later".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: weight.path)
        let after = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(after, 2)
    }

    func testNestedSymlinkFailsClosedInsteadOfReusingStaleAssets() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let weight = directory.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin")
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let before = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(before, 1)
        try FileManager.default.removeItem(at: weight)
        try Data("later".utf8).write(to: directory.appendingPathComponent("replacement.bin"))
        try FileManager.default.createSymbolicLink(at: weight, withDestinationURL: directory.appendingPathComponent("replacement.bin"))
        do {
            _ = try await cache.withModel(at: directory, load: load) { $0 }
            XCTFail("Do not load or reuse models containing untracked symlink targets")
        } catch {
            let loadCount = await loads.value
            XCTAssertEqual(loadCount, 1)
        }
    }

    func testRemovedDirectoryDoesNotReturnStaleSessionAndReinstallReloads() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let first = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(first, 1)
        try FileManager.default.removeItem(at: directory)
        do {
            _ = try await cache.withModel(at: directory, load: load) { $0 }
            XCTFail("Removed model must not be used")
        } catch {
            // A missing directory must fail before invoking the loader or operation.
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let second = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(second, 2)
    }

    func testSwitchingFoldersKeepsOnlyCurrentSession() async throws {
        let firstDirectory = try fixture()
        let secondDirectory = try fixture()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        let first = try await cache.withModel(at: firstDirectory, load: load) { $0 }
        let second = try await cache.withModel(at: secondDirectory, load: load) { $0 }
        let back = try await cache.withModel(at: firstDirectory, load: load) { $0 }
        XCTAssertEqual([first, second, back], [1, 2, 3])
    }

    func testFailedInitializationIsRetriedRatherThanCached() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let load: @Sendable (URL) async throws -> Int = { _ in
            let attempt = await loads.next()
            if attempt == 1 { throw TestFailure.expected }
            return attempt
        }
        do {
            _ = try await cache.withModel(at: directory, load: load) { $0 }
            XCTFail("First load should fail")
        } catch TestFailure.expected {
            // Expected.
        }
        let retried = try await cache.withModel(at: directory, load: load) { $0 }
        XCTAssertEqual(retried, 2)
    }

    func testOverlappingCallsNeverUseSessionConcurrently() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SerializedModelCache<Int>()
        let loads = LoadCounter()
        let probe = ConcurrencyProbe()
        let load: @Sendable (URL) async throws -> Int = { _ in await loads.next() }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await cache.withModel(at: directory, load: load) { model in
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                        return model
                    }
                }
            }
            for try await result in group { XCTAssertEqual(result, 1) }
        }
        let maxActive = await probe.maximum
        XCTAssertEqual(maxActive, 1)
        let loadCount = await loads.value
        XCTAssertEqual(loadCount, 1)
    }
}

private enum TestFailure: Error { case expected }

private actor LoadCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
    var value: Int { count }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
