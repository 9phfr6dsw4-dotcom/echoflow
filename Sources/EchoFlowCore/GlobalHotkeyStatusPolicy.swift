import Foundation

/// Builds user-facing diagnostics for the system-wide keyboard event monitor.
public enum GlobalHotkeyStatusPolicy {
    public static let enabledPreferenceKey = "EchoFlow.globalHotkeyEnabled"

    public static func storedEnabledPreference(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: enabledPreferenceKey) as? Bool
    }

    public static func setEnabledPreference(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledPreferenceKey)
    }

    public static func shouldActivateListener(
        accessibilityGranted: Bool,
        previouslyEnabled: Bool?
    ) -> Bool {
        accessibilityGranted && (previouslyEnabled ?? true)
    }

    public static func shouldStopHoldRecording(
        accessibilityGranted: Bool,
        holdRecordingActive: Bool
    ) -> Bool {
        holdRecordingActive && !accessibilityGranted
    }

    public static func message(
        accessibilityGranted: Bool,
        hotkeyEnabledPreference: Bool,
        globalMonitorInstalled: Bool,
        receivedEventCount: Int,
        configuredHotkey: String,
        lastEventDescription: String?,
        lastRecognizedAction: String?
    ) -> String {
        guard accessibilityGranted else {
            return "Not listening: choose Request Accessibility Access, enable EchoFlow in System Settings → Privacy & Security → Device Control and Data Access, then return to EchoFlow. Input Monitoring is not required."
        }
        guard hotkeyEnabledPreference else {
            return "Hotkey is off. Enable it once; EchoFlow remembers this choice and restores it at launch."
        }
        guard globalMonitorInstalled else {
            return "The system-wide keyboard listener did not start. Choose Enable Hotkey to retry; if registration keeps failing, restart EchoFlow and check its Accessibility permission."
        }
        guard receivedEventCount > 0 else {
            return "Listener active for \(configuredHotkey); no keyboard events received yet. Press the selected hotkey while another app is frontmost to verify it. Input Monitoring is not required when Accessibility is allowed."
        }

        let eventWord = receivedEventCount == 1 ? "keyboard event" : "keyboard events"
        let lastEvent = lastEventDescription ?? "event details unavailable"
        if let lastRecognizedAction {
            return "Listener active for \(configuredHotkey); received \(receivedEventCount) \(eventWord); last: \(lastEvent). Recognized hotkey: \(lastRecognizedAction)."
        }
        return "Listener active for \(configuredHotkey); received \(receivedEventCount) \(eventWord); last: \(lastEvent). No configured hotkey has been recognized yet."
    }
}
