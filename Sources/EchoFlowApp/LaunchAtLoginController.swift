import EchoFlowCore
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    static let preferenceKey = "EchoFlow.launchAtLogin"

    private(set) var isEnabled: Bool
    private(set) var statusMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service = SMAppService.mainApp

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedValue = defaults.object(forKey: Self.preferenceKey) as? Bool
        self.isEnabled = LaunchAtLoginPreferencePolicy.isEnabled(storedValue: storedValue)
        if storedValue == nil {
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            registerDefaultIfPossible()
        } else {
            refreshStatus()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        if enabled {
            registerIfNeeded()
        } else {
            unregisterIfNeeded()
        }
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            statusMessage = nil
        case .requiresApproval:
            statusMessage = "macOS needs your approval. Open Login Items and allow EchoFlow."
        case .notRegistered:
            statusMessage = isEnabled
                ? "Launch at login is selected but is not active. Enable EchoFlow in Login Items, or turn this option off and on to retry."
                : nil
        case .notFound:
            statusMessage = isEnabled
                ? "macOS could not find an eligible EchoFlow login item. Check Login Items and make sure you're using the installed app."
                : nil
        @unknown default:
            statusMessage = "macOS could not confirm EchoFlow's login-item status."
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerDefaultIfPossible() {
        guard ProcessInfo.processInfo.environment["CI"] != "true" else { return }
        guard service.status == .notRegistered else {
            refreshStatus()
            return
        }
        registerIfNeeded()
    }

    private func registerIfNeeded() {
        switch service.status {
        case .enabled, .requiresApproval:
            refreshStatus()
        case .notRegistered:
            do {
                try service.register()
                refreshStatus()
            } catch {
                if service.status == .requiresApproval {
                    refreshStatus()
                } else {
                    statusMessage = "Could not enable launch at login: \(error.localizedDescription)"
                }
            }
        case .notFound:
            refreshStatus()
        @unknown default:
            refreshStatus()
        }
    }

    private func unregisterIfNeeded() {
        guard service.status != .notRegistered else {
            refreshStatus()
            return
        }
        do {
            try service.unregister()
            refreshStatus()
        } catch {
            if service.status == .enabled || service.status == .requiresApproval {
                isEnabled = true
                defaults.set(true, forKey: Self.preferenceKey)
            }
            statusMessage = "Could not disable launch at login: \(error.localizedDescription)"
        }
    }
}
