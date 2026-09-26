import XCTest
import EchoFlowCore

final class TranscriptionBackendTests: XCTestCase {
    private func catalog() throws -> ModelCatalog {
        try ModelCatalogTestSupport.catalog()
    }

    func testAppleSpeechNeedsNoModelDownload() throws {
        let backend = TranscriptionBackend.resolve(
            engineID: ModelSelection.appleSpeechEngineID,
            catalog: try catalog(),
            installedDownloadIDs: []
        )

        XCTAssertEqual(backend, .appleSpeech)
    }

    func testParakeetRoutesOnlyWhenItsVerifiedDownloadIsInstalled() throws {
        let catalog = try catalog()

        XCTAssertEqual(
            TranscriptionBackend.resolve(
                engineID: ModelSelection.parakeetEngineID,
                catalog: catalog,
                installedDownloadIDs: []
            ),
            .unavailable(engineID: ModelSelection.parakeetEngineID)
        )
        XCTAssertEqual(
            TranscriptionBackend.resolve(
                engineID: ModelSelection.parakeetEngineID,
                catalog: catalog,
                installedDownloadIDs: ["parakeet-v3"]
            ),
            .parakeetV3
        )
    }

    func testWhisperRoutesOnlyWhenItsVerifiedDownloadIsInstalled() throws {
        let catalog = try catalog()
        let engineID = "whisper-large-v3-turbo"

        XCTAssertEqual(
            TranscriptionBackend.resolve(engineID: engineID, catalog: catalog, installedDownloadIDs: []),
            .unavailable(engineID: engineID)
        )
        XCTAssertEqual(
            TranscriptionBackend.resolve(
                engineID: engineID,
                catalog: catalog,
                installedDownloadIDs: [engineID]
            ),
            .whisperLargeV3Turbo
        )
    }

    func testUnknownEngineCannotResolveToATranscriptionBackend() throws {
        let engineID = "unknown-engine"
        XCTAssertEqual(
            TranscriptionBackend.resolve(engineID: engineID, catalog: try catalog(), installedDownloadIDs: []),
            .unavailable(engineID: engineID)
        )
    }
}
