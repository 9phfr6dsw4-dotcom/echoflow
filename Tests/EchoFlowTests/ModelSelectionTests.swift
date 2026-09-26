import XCTest
import EchoFlowCore

final class ModelSelectionTests: XCTestCase {
    func testInstalledParakeetBecomesDefaultWhenNoEngineWasChosen() throws {
        let catalog = try ModelCatalogTestSupport.catalog()
        let selection = ModelSelection(
            catalog: catalog,
            installedDownloadIDs: ["parakeet-v3"]
        )

        XCTAssertEqual(selection.engineID, "parakeet-v3")
    }

    func testExplicitAppleSpeechPreferenceIsPreservedWhenParakeetIsInstalled() throws {
        let catalog = try ModelCatalogTestSupport.catalog()
        let selection = ModelSelection(
            catalog: catalog,
            preferredEngineID: ModelSelection.appleSpeechEngineID,
            installedDownloadIDs: ["parakeet-v3"]
        )

        XCTAssertEqual(selection.engineID, ModelSelection.appleSpeechEngineID)
    }
}
