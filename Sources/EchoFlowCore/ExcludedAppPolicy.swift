import Foundation

public struct ExcludedApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = Self.normalizeBundleIdentifier(bundleIdentifier)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func normalizeBundleIdentifier(_ bundleIdentifier: String) -> String {
        bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            displayName: try container.decode(String.self, forKey: .displayName)
        )
    }
}

public struct ExcludedAppPolicy: Codable, Equatable, Sendable {
    public private(set) var defaultExcludedApplications: [ExcludedApplication]
    public private(set) var userExcludedApplications: [ExcludedApplication]

    private enum CodingKeys: String, CodingKey {
        case defaultExcludedApplications
        case userExcludedApplications
    }

    public init() {
        self.defaultExcludedApplications = Self.builtInDefaultExclusions
        self.userExcludedApplications = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent([ExcludedApplication].self, forKey: .defaultExcludedApplications)
        self.defaultExcludedApplications = Self.builtInDefaultExclusions
        self.userExcludedApplications = Self.uniqueApplications(
            try container.decode([ExcludedApplication].self, forKey: .userExcludedApplications)
        )
    }

    public static func resolvePersisted(_ data: Data?) -> ExcludedAppPolicy? {
        guard let data else { return ExcludedAppPolicy() }
        return try? JSONDecoder().decode(ExcludedAppPolicy.self, from: data)
    }

    public func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalizedIdentifier = ExcludedApplication.normalizeBundleIdentifier(bundleIdentifier)
        guard !normalizedIdentifier.isEmpty else { return false }

        return (defaultExcludedApplications + userExcludedApplications)
            .contains { $0.bundleIdentifier == normalizedIdentifier }
    }

    public mutating func addUserExclusion(bundleIdentifier: String, displayName: String) {
        let application = ExcludedApplication(bundleIdentifier: bundleIdentifier, displayName: displayName)
        guard !application.bundleIdentifier.isEmpty else { return }
        guard !defaultExcludedApplications.contains(where: {
            $0.bundleIdentifier == application.bundleIdentifier
        }) else { return }

        if let index = userExcludedApplications.firstIndex(where: {
            $0.bundleIdentifier == application.bundleIdentifier
        }) {
            userExcludedApplications[index] = application
        } else {
            userExcludedApplications.append(application)
        }
    }

    public mutating func removeUserExclusion(bundleIdentifier: String) {
        let normalizedIdentifier = ExcludedApplication.normalizeBundleIdentifier(bundleIdentifier)
        guard !normalizedIdentifier.isEmpty else { return }
        userExcludedApplications.removeAll { $0.bundleIdentifier == normalizedIdentifier }
    }

    private static let builtInDefaultExclusions: [ExcludedApplication] = [
        ExcludedApplication(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        ExcludedApplication(bundleIdentifier: "com.agilebits.onepassword7", displayName: "1Password 7"),
        ExcludedApplication(bundleIdentifier: "com.agilebits.onepassword", displayName: "1Password"),
        ExcludedApplication(bundleIdentifier: "com.lastpass.lastpass", displayName: "LastPass"),
        ExcludedApplication(bundleIdentifier: "com.bitwarden.desktop", displayName: "Bitwarden")
    ]

    private static func uniqueApplications(_ applications: [ExcludedApplication]) -> [ExcludedApplication] {
        var unique: [ExcludedApplication] = []
        for application in applications where !application.bundleIdentifier.isEmpty {
            if let index = unique.firstIndex(where: {
                $0.bundleIdentifier == application.bundleIdentifier
            }) {
                unique[index] = application
            } else {
                unique.append(application)
            }
        }
        return unique
    }
}
