import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class LocalLearningViewModel {
    private(set) var store: LocalLearningStore
    var errorMessage: String?

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private var canPersist = true

    init(storageURL: URL? = nil) {
        let resolvedURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = resolvedURL
        do {
            self.store = try LocalLearningFileStore.load(from: resolvedURL)
        } catch {
            self.store = LocalLearningStore()
            self.canPersist = false
            self.errorMessage = "Saved local learning data could not be read. EchoFlow will not overwrite it: \(error.localizedDescription)"
        }
    }

    var askBeforeAdding: Bool {
        get { store.policy.askBeforeAdding }
        set {
            store.policy.askBeforeAdding = newValue
            persist()
        }
    }

    func observeTranscriptCorrection(original: String, corrected: String) {
        guard canPersist else { return }
        let corrections = TranscriptCorrectionExtractor.extract(from: original, to: corrected)
        guard !corrections.isEmpty else { return }
        for correction in corrections {
            _ = store.observeCorrection(original: correction.original, replacement: correction.replacement)
        }
        persist()
    }

    @discardableResult
    func confirmAddition(of term: String) -> Bool {
        guard canPersist else { return false }
        let changed = store.confirmAddition(of: term)
        if changed { persist() }
        return changed
    }

    @discardableResult
    func rejectAddition(of term: String) -> Bool {
        guard canPersist else { return false }
        let changed = store.rejectAddition(of: term)
        if changed { persist() }
        return changed
    }

    @discardableResult
    func setPinned(_ isPinned: Bool, for term: String) -> Bool {
        guard canPersist else { return false }
        let changed = store.setPinned(isPinned, for: term)
        if changed { persist() }
        return changed
    }

    @discardableResult
    func removeLearnedTerm(_ term: String) -> Bool {
        guard canPersist else { return false }
        let changed = store.removeLearnedTerm(term)
        if changed { persist() }
        return changed
    }

    private func persist() {
        guard canPersist else { return }
        do {
            try LocalLearningFileStore.save(store, to: storageURL)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save local learning data: \(error.localizedDescription)"
        }
    }

    private static func defaultStorageURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportDirectory.appendingPathComponent("EchoFlow/local-learning.json")
    }
}
