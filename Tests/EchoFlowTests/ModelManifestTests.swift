import Foundation
import XCTest

final class ModelManifestTests: XCTestCase {
    private func manifestURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let packageFile = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageFile.path) {
                return directory.appendingPathComponent("Resources/model-manifest.json")
            }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "Resources/model-manifest.json")
    }

    private func loadManifest(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = manifestURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Pinned model manifest is missing", file: file, line: line)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    func testManifestOffersExactlyTheThreeRequestedEngines() throws {
        let manifest = try loadManifest()
        let engines = try XCTUnwrap(manifest["engines"] as? [[String: Any]])
        let ids = engines.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["apple-speech", "parakeet-v3", "whisper-large-v3-turbo"])
    }

    func testPinnedDownloadsHaveExactByteTotalsAndParakeetVocabularyIsRequired() throws {
        let manifest = try loadManifest()
        let downloads = try XCTUnwrap(manifest["downloads"] as? [[String: Any]])
        let totals = Dictionary(uniqueKeysWithValues: downloads.compactMap { item -> (String, Int)? in
            guard let id = item["id"] as? String, let bytes = item["bytes"] as? Int else { return nil }
            return (id, bytes)
        })
        XCTAssertEqual(totals["parakeet-v3"], 632_169_729)
        XCTAssertEqual(totals["parakeet-ctc-0.6b-coreml"], 2_374_186_501)
        XCTAssertEqual(totals["whisper-large-v3-turbo"], 3_199_676_429)
        XCTAssertEqual(downloads.first(where: { $0["id"] as? String == "parakeet-ctc-0.6b-coreml" })?["optional"] as? Bool, false)
    }

    func testEveryDownloadFileIsPinnedAndHasAValidSha256() throws {
        let manifest = try loadManifest()
        let downloads = try XCTUnwrap(manifest["downloads"] as? [[String: Any]])
        XCTAssertFalse(downloads.isEmpty)

        for download in downloads {
            let files = try XCTUnwrap(download["files"] as? [[String: Any]])
            XCTAssertFalse(files.isEmpty)
            var byteTotal = 0
            for file in files {
                let repo = try XCTUnwrap(file["repo"] as? String)
                let revision = try XCTUnwrap(file["revision"] as? String)
                let sourcePath = try XCTUnwrap(file["sourcePath"] as? String)
                let destinationPath = try XCTUnwrap(file["destinationPath"] as? String)
                let size = try XCTUnwrap(file["size"] as? Int)
                let digest = try XCTUnwrap(file["sha256"] as? String)
                XCTAssertFalse(repo.isEmpty)
                XCTAssertEqual(revision.count, 40)
                XCTAssertTrue(revision.allSatisfy(\.isHexDigit))
                XCTAssertFalse(sourcePath.isEmpty)
                XCTAssertFalse(destinationPath.split(separator: "/").contains(".."))
                XCTAssertGreaterThan(size, 0)
                XCTAssertEqual(digest.count, 64)
                XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
                byteTotal += size
            }
            XCTAssertEqual(byteTotal, try XCTUnwrap(download["bytes"] as? Int))
        }
    }
}
