import Foundation
@testable import EchoFlowCore

enum ModelCatalogTestSupport {
    static func catalog() throws -> ModelCatalog {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot.appendingPathComponent("Resources/model-manifest.json")
        return try ModelCatalog(data: Data(contentsOf: manifestURL))
    }
}
