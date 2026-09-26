import Foundation

/// Produces the user-initiated install and removal sets for each engine.
public enum ModelDownloadPlan {
    public static let parakeetVocabularyDownloadID = "parakeet-ctc-0.6b-coreml"

    public static func downloadsForEngine(engineID: String, catalog: ModelCatalog) -> [ModelDownload] {
        guard let engine = catalog.engine(id: engineID) else { return [] }

        var downloadIDs: [String] = []
        if let baseID = engine.downloadId {
            downloadIDs.append(baseID)
        }
        if engineID == ModelSelection.parakeetEngineID {
            downloadIDs.append(parakeetVocabularyDownloadID)
        }

        var seen = Set<String>()
        return downloadIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return catalog.download(id: id)
        }
    }

    public static func downloadIDsForRemoval(engineID: String, catalog: ModelCatalog) -> [String] {
        downloadsForEngine(engineID: engineID, catalog: catalog).map(\.id)
    }

    public static func downloadsForExplicitInstall(
        engineID: String,
        catalog: ModelCatalog,
        installedDownloadIDs: Set<String>
    ) -> [ModelDownload] {
        downloadsForEngine(engineID: engineID, catalog: catalog)
            .filter { !installedDownloadIDs.contains($0.id) }
    }

    public static func totalBytes(_ downloads: [ModelDownload]) -> Int {
        downloads.reduce(0) { partial, download in
            let (total, overflow) = partial.addingReportingOverflow(download.bytes)
            return overflow ? Int.max : total
        }
    }
}
