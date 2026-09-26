import XCTest
@testable import EchoFlowCore

final class ModelDownloadPlanTests: XCTestCase {
    func testParakeetIsOneRequiredEngineInstallIncludingVocabulary() throws {
        let catalog = try ModelCatalogTestSupport.catalog()

        let downloads = ModelDownloadPlan.downloadsForEngine(
            engineID: ModelSelection.parakeetEngineID,
            catalog: catalog
        )

        XCTAssertEqual(downloads.map(\.id), ["parakeet-v3", "parakeet-ctc-0.6b-coreml"])
        XCTAssertTrue(downloads.allSatisfy { !$0.optional })
    }

    func testDeletingParakeetRemovesItsModelAndVocabularyDownloads() throws {
        let catalog = try ModelCatalogTestSupport.catalog()

        let downloadIDs = ModelDownloadPlan.downloadIDsForRemoval(
            engineID: ModelSelection.parakeetEngineID,
            catalog: catalog
        )

        XCTAssertEqual(downloadIDs, ["parakeet-v3", "parakeet-ctc-0.6b-coreml"])
    }

    func testFirstParakeetDownloadIncludesModelAndVocabularyCompanionInTotal() throws {
        let catalog = try ModelCatalogTestSupport.catalog()
        let downloads = ModelDownloadPlan.downloadsForExplicitInstall(
            engineID: ModelSelection.parakeetEngineID,
            catalog: catalog,
            installedDownloadIDs: []
        )

        XCTAssertEqual(downloads.map(\.id), ["parakeet-v3", "parakeet-ctc-0.6b-coreml"])
        XCTAssertEqual(ModelDownloadPlan.totalBytes(downloads), 3_006_356_230)
    }

    func testParakeetDownloadDoesNotRedownloadAlreadyInstalledCompanion() throws {
        let catalog = try ModelCatalogTestSupport.catalog()

        let downloads = ModelDownloadPlan.downloadsForExplicitInstall(
            engineID: ModelSelection.parakeetEngineID,
            catalog: catalog,
            installedDownloadIDs: ["parakeet-ctc-0.6b-coreml"]
        )

        XCTAssertEqual(downloads.map(\.id), ["parakeet-v3"])
    }

    func testOtherEngineInstallPlanDoesNotIncludeParakeetCompanion() throws {
        let catalog = try ModelCatalogTestSupport.catalog()

        let downloads = ModelDownloadPlan.downloadsForExplicitInstall(
            engineID: "whisper-large-v3-turbo",
            catalog: catalog,
            installedDownloadIDs: []
        )

        XCTAssertEqual(downloads.map(\.id), ["whisper-large-v3-turbo"])
    }
}
