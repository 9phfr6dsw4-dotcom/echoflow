import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class SmartLinksViewModel {
    static let preferenceKey = "EchoFlow.smartLinks"

    private(set) var store: SmartLinkStore
    private(set) var canMutate = true
    var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferenceKey) {
            do {
                self.store = try JSONDecoder().decode(SmartLinkStore.self, from: data)
            } catch {
                self.store = SmartLinkStore()
                self.canMutate = false
                self.errorMessage = "Saved smart links could not be read. Changes are disabled to protect the existing settings: \(error.localizedDescription)"
            }
        } else {
            self.store = SmartLinkStore()
        }
    }

    @discardableResult
    func add(phrase: String, destinationURL: String) throws -> SmartLink {
        try updateStore { try $0.add(phrase: phrase, destinationURL: destinationURL) }
    }

    @discardableResult
    func edit(id: UUID, phrase: String, destinationURL: String) throws -> SmartLink {
        try updateStore { try $0.edit(id: id, phrase: phrase, destinationURL: destinationURL) }
    }

    @discardableResult
    func remove(id: UUID) throws -> Bool {
        try updateStore { $0.remove(id: id) }
    }

    func applying(to transcript: String) -> String {
        store.applying(to: transcript)
    }

    private func updateStore<Result>(_ update: (inout SmartLinkStore) throws -> Result) throws -> Result {
        guard canMutate else { throw SmartLinksViewModelError.mutationsDisabled }
        var updatedStore = store
        do {
            let result = try update(&updatedStore)
            guard updatedStore != store else {
                errorMessage = nil
                return result
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(updatedStore), forKey: Self.preferenceKey)
            store = updatedStore
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

private enum SmartLinksViewModelError: LocalizedError, Sendable {
    case mutationsDisabled

    var errorDescription: String? {
        "Smart-link settings cannot be changed because the saved settings could not be read."
    }
}
