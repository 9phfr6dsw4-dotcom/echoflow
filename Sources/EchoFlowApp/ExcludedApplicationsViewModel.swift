import AppKit
import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class ExcludedApplicationsViewModel {
    private(set) var policy: ExcludedAppPolicy
    var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    static let defaultsKey = "EchoFlow.excludedAppPolicy"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = ExcludedAppPolicy.resolvePersisted(defaults.data(forKey: Self.defaultsKey)) {
            self.policy = saved
        } else {
            self.policy = ExcludedAppPolicy()
            self.errorMessage = "Saved excluded-app settings could not be read. Dictation and voice actions will remain blocked until the setting is repaired."
        }
    }

    func addApplication(at url: URL) {
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "EchoFlow could not read an app bundle identifier from that application."
            return
        }
        let displayName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
        policy.addUserExclusion(bundleIdentifier: bundleIdentifier, displayName: displayName)
        persist()
        errorMessage = nil
    }

    func removeApplication(bundleIdentifier: String) {
        policy.removeUserExclusion(bundleIdentifier: bundleIdentifier)
        persist()
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(policy), forKey: Self.defaultsKey)
        } catch {
            errorMessage = "Could not save excluded apps: \(error.localizedDescription)"
        }
    }
}
