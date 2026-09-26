import Foundation

public enum VoiceMemoFolderBookmarkError: Error, LocalizedError, Sendable {
    case notAnExistingDirectory(URL)
    case bookmarkUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAnExistingDirectory(let url):
            "Select an existing folder for voice memos: \(url.path)"
        case .bookmarkUnavailable:
            "The saved voice memo folder could not be resolved. Choose the folder again in Settings."
        }
    }
}

/// Persists a normal URL bookmark for the selected folder. EchoFlow's distributed
/// app is not App Sandbox-enabled, so this deliberately does not request a
/// sandbox-only security scope or alter the app's existing entitlements.
public final class VoiceMemoFolderBookmarkStore {
    public static let bookmarkDefaultsKey = "EchoFlow.voiceMemoFolderBookmark"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    public func save(directory: URL) throws {
        guard Self.isExistingDirectory(directory, fileManager: fileManager) else {
            throw VoiceMemoFolderBookmarkError.notAnExistingDirectory(directory)
        }
        let bookmark = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    }

    public func resolveDirectory() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return nil }
        var isStale = false
        let directory: URL
        do {
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw VoiceMemoFolderBookmarkError.bookmarkUnavailable
        }
        guard Self.isExistingDirectory(directory, fileManager: fileManager) else {
            throw VoiceMemoFolderBookmarkError.notAnExistingDirectory(directory)
        }
        if isStale { try save(directory: directory) }
        return directory
    }

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
