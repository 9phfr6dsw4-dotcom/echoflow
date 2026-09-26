import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class TranscriptTextCleanupViewModel {
    static let defaultsKey = "EchoFlow.transcriptTextCleanupSettings"

    private(set) var settings: TranscriptTextCleanupSettings
    private(set) var canMutate = true
    var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let aiCleanup = OnDeviceTranscriptCleanupService()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                self.settings = try JSONDecoder().decode(TranscriptTextCleanupSettings.self, from: data)
            } catch {
                self.settings = TranscriptTextCleanupSettings()
                self.canMutate = false
                self.errorMessage = "Saved text-cleanup settings could not be read. Changes are disabled to protect the existing settings: \(error.localizedDescription)"
            }
        } else {
            self.settings = TranscriptTextCleanupSettings()
        }
    }

    var availabilityMessage: String { aiCleanup.availabilityMessage }

    func setRemoveFillerWords(_ enabled: Bool) {
        updateSettings { $0.removeFillerWords = enabled }
    }

    func setRemoveFalseStarts(_ enabled: Bool) {
        updateSettings { $0.removeFalseStarts = enabled }
    }

    func setConvertSpokenNumbers(_ enabled: Bool) {
        updateSettings { $0.convertSpokenNumbersToDigits = enabled }
    }

    func setAIEnabled(_ enabled: Bool) {
        updateSettings { $0.aiCleanupEnabled = enabled }
    }

    func setStyle(_ style: AppTranscriptWritingStyle, for profile: AppTextCleanupProfile) {
        updateSettings { $0.setStyle(style, for: profile) }
    }

    func addApplication(at url: URL) {
        guard canMutate else { return }
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "EchoFlow could not read an app bundle identifier from that application."
            return
        }
        let displayName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
        let profile = AppTextCleanupProfile(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            style: settings.style(forBundleIdentifier: bundleIdentifier)
        )
        updateSettings { $0.setStyle(profile.style, for: profile) }
    }

    func removeProfile(_ profile: AppTextCleanupProfile) {
        guard !TranscriptTextCleanupSettings.defaultApplicationProfiles.contains(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(profile.bundleIdentifier) == .orderedSame
        }) else { return }
        updateSettings { $0.removeProfile(bundleIdentifier: profile.bundleIdentifier) }
    }

    func cleanedText(_ transcript: String, targetBundleIdentifier: String?) async -> String {
        let plan = TranscriptTextCleanupPolicy.plan(
            transcript,
            settings: settings,
            targetBundleIdentifier: targetBundleIdentifier
        )
        guard let aiStyle = plan.aiStyle else { return plan.text }
        let candidate = await aiCleanup.clean(plan.text, style: aiStyle)
        return TranscriptAIOutputPolicy.deliveredText(
            candidate,
            preparedText: plan.text,
            fallbackText: plan.rawText
        )
    }

    private func updateSettings(_ update: (inout TranscriptTextCleanupSettings) -> Void) {
        guard canMutate else { return }
        var updated = settings
        update(&updated)
        guard updated != settings else {
            errorMessage = nil
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(updated), forKey: Self.defaultsKey)
            settings = updated
            errorMessage = nil
        } catch {
            errorMessage = "Could not save text-cleanup settings: \(error.localizedDescription)"
        }
    }
}
