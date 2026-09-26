import Foundation

/// Checks whether the installed Apple Speech assets match a preferred language.
/// Region variants are equivalent, but distinct scripts require separate preparation.
public enum PreparedSpeechLocalePolicy {
    public static func isPrepared(
        preparedIdentifier: String?,
        requestedIdentifier: String,
        assetsInstalled: Bool
    ) -> Bool {
        guard assetsInstalled,
              let preparedIdentifier,
              let prepared = components(in: preparedIdentifier),
              let requested = components(in: requestedIdentifier) else {
            return false
        }
        return prepared.language == requested.language && prepared.script == requested.script
    }

    private struct LocaleComponents {
        let language: String
        let script: String?
    }

    private static func components(in identifier: String) -> LocaleComponents? {
        let subtags = identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        guard let first = subtags.first else { return nil }
        let language = first.lowercased()
        guard !language.isEmpty else { return nil }
        let script = subtags.dropFirst().first {
            $0.count == 4 && $0.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        }?.lowercased()
        return LocaleComponents(language: language, script: script)
    }
}
