import AppKit
import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class VoiceMemoDestinationController {
    private(set) var selectedDirectoryURL: URL?
    private(set) var errorMessage: String?

    @ObservationIgnored private let bookmarkStore: VoiceMemoFolderBookmarkStore

    init(defaults: UserDefaults = .standard) {
        let store = VoiceMemoFolderBookmarkStore(defaults: defaults)
        bookmarkStore = store
        do {
            selectedDirectoryURL = try store.resolveDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedDirectoryDescription: String {
        selectedDirectoryURL?.path ?? "No voice memo folder selected"
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Voice Memo Folder"
        panel.message = "Each voice memo will be saved as a new Markdown file in this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = selectedDirectoryURL

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            try bookmarkStore.save(directory: directory)
            selectedDirectoryURL = directory
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolvedDirectory() -> URL? {
        do {
            let directory = try bookmarkStore.resolveDirectory()
            selectedDirectoryURL = directory
            if directory != nil { errorMessage = nil }
            return directory
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
