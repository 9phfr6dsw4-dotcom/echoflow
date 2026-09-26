import Foundation

/// Persists local learning state independently of transcript history.
public enum LocalLearningFileStore {
    /// Loads a learning store from `url`, returning a default store only when the
    /// file is absent. Read and decoding errors are propagated to the caller.
    public static func load(from url: URL) throws -> LocalLearningStore {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LocalLearningStore()
        }

        return try JSONDecoder().decode(LocalLearningStore.self, from: data)
    }

    /// Atomically saves learning state to `url`, creating its parent directory
    /// when needed. The caller chooses a location independent of transcript data.
    public static func save(_ store: LocalLearningStore, to url: URL) throws {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
    }
}
