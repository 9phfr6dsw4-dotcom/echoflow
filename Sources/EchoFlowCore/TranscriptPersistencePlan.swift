import Foundation

/// Keeps transcript retention and Markdown archiving as independent user choices.
public struct TranscriptPersistencePlan: Equatable, Sendable {
    public let saveToLocalHistory: Bool
    public let writeMarkdownArchive: Bool

    public init(historyEnabled: Bool, archiveDirectorySelected: Bool) {
        self.saveToLocalHistory = historyEnabled
        self.writeMarkdownArchive = archiveDirectorySelected
    }
}
