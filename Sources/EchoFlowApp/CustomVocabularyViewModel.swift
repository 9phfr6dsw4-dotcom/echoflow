import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class CustomVocabularyViewModel {
    private(set) var store: CustomVocabularyStore
    private(set) var canMutate = true
    var errorMessage: String?

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        let resolvedFileURL = fileURL ?? CustomVocabularyFileStore.defaultURL
        self.fileURL = resolvedFileURL

        do {
            self.store = try CustomVocabularyFileStore.load(from: resolvedFileURL)
        } catch {
            self.store = CustomVocabularyStore()
            self.canMutate = false
            self.errorMessage = "Saved custom vocabulary could not be read. Mutations are disabled to protect the existing file: \(error.localizedDescription)"
        }
    }

    var terms: [CustomVocabularyTerm] {
        store.terms
    }

    @discardableResult
    func addTerm(_ rawTerm: String) throws -> CustomVocabularyTerm {
        try updateStore { try $0.addTerm(rawTerm) }
    }

    @discardableResult
    func editTerm(id: UUID, to rawTerm: String) throws -> CustomVocabularyTerm {
        try updateStore { try $0.editTerm(id: id, to: rawTerm) }
    }

    @discardableResult
    func removeTerm(id: UUID) throws -> Bool {
        try updateStore { $0.removeTerm(id: id) }
    }

    private func updateStore<Result>(
        _ update: (inout CustomVocabularyStore) throws -> Result
    ) throws -> Result {
        guard canMutate else {
            throw CustomVocabularyViewModelError.mutationsDisabled
        }

        var updatedStore = store
        do {
            let result = try update(&updatedStore)
            guard updatedStore != store else {
                errorMessage = nil
                return result
            }

            try CustomVocabularyFileStore.save(updatedStore, to: fileURL)
            store = updatedStore
            errorMessage = nil
            return result
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? CustomVocabularyStoreError {
        case .invalidTerm:
            "Enter a non-empty vocabulary term."
        case .termTooLong(let maximumLength):
            "Vocabulary terms must be no longer than \(maximumLength) characters."
        case .duplicateTerm:
            "That term is already in your vocabulary."
        case .termNotFound:
            "That vocabulary term no longer exists."
        case nil:
            "Could not save custom vocabulary: \(error.localizedDescription)"
        }
    }
}

private enum CustomVocabularyViewModelError: LocalizedError, Sendable {
    case mutationsDisabled

    var errorDescription: String? {
        "Custom vocabulary mutations are disabled because the saved file could not be read."
    }
}

@MainActor
private enum CustomVocabularyFileStore {
    static var defaultURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupportDirectory
            .appendingPathComponent("EchoFlow", isDirectory: true)
            .appendingPathComponent("custom-vocabulary.json", isDirectory: false)
    }

    static func load(from url: URL) throws -> CustomVocabularyStore {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CustomVocabularyStore()
        }

        return try JSONDecoder().decode(CustomVocabularyStore.self, from: data)
    }

    static func save(_ store: CustomVocabularyStore, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: url, options: .atomic)
    }
}
