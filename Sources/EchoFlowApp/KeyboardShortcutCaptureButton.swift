import AppKit
import EchoFlowCore
import Observation
import SwiftUI

struct KeyboardShortcutCaptureButton: View {
    let title: String
    let onCapture: @MainActor @Sendable (KeyboardShortcutDescriptor) -> Void

    @State private var capture = KeyboardShortcutCaptureModel()

    var body: some View {
        HStack(spacing: 8) {
            Button(capture.isCapturing ? "Press a key chord…" : title) {
                capture.begin(onCapture: onCapture)
            }
            .disabled(capture.isCapturing)

            if capture.isCapturing {
                Button("Cancel") { capture.cancel() }
                    .buttonStyle(.borderless)
            }

            if let message = capture.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { capture.cancel() }
    }
}

@MainActor
@Observable
private final class KeyboardShortcutCaptureModel {
    private(set) var isCapturing = false
    private(set) var message: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var captureLatch: ShortcutCaptureLatch?

    func begin(onCapture: @escaping @MainActor @Sendable (KeyboardShortcutDescriptor) -> Void) {
        cancel()
        message = "Press a non-modifier key with at least one modifier. The captured keystroke will not be sent to the front app."
        isCapturing = true
        let latch = ShortcutCaptureLatch()
        captureLatch = latch
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let descriptor = Self.descriptor(from: event) else {
                Task { @MainActor [weak self] in
                    self?.message = "Use a key chord such as ⌃⌥K; bare keys are not accepted."
                }
                return nil
            }
            guard latch.claim() else { return nil }
            Task { @MainActor [weak self] in
                onCapture(descriptor)
                self?.cancel()
            }
            return nil
        }
        if monitor == nil {
            isCapturing = false
            captureLatch = nil
            message = "macOS could not start shortcut capture."
            return
        }
        NotificationCenter.default.post(name: .echoFlowShortcutCaptureDidBegin, object: nil)
    }

    func cancel() {
        let wasCapturing = monitor != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        captureLatch = nil
        isCapturing = false
        if wasCapturing {
            NotificationCenter.default.post(name: .echoFlowShortcutCaptureDidEnd, object: nil)
        }
    }

    nonisolated private static func descriptor(from event: NSEvent) -> KeyboardShortcutDescriptor? {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var flags: KeyboardShortcutModifierFlags = []
        if eventFlags.contains(.command) { flags.insert(.command) }
        if eventFlags.contains(.shift) { flags.insert(.shift) }
        if eventFlags.contains(.option) { flags.insert(.option) }
        if eventFlags.contains(.control) { flags.insert(.control) }
        if eventFlags.contains(.function) { flags.insert(.function) }

        guard !flags.isEmpty else { return nil }
        let character = event.charactersIgnoringModifiers
        let keyName: String
        switch event.keyCode {
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 49: keyName = "Space"
        case 51: keyName = "Delete"
        case 53: keyName = "Escape"
        case 71: keyName = "Clear"
        case 76: keyName = "Keypad Enter"
        default:
            keyName = character?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nonEmpty
                ?? "Key \(event.keyCode)"
        }

        let modifierLabel = [
            (KeyboardShortcutModifierFlags.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘"),
            (.function, "fn ")
        ]
        .compactMap { flags.contains($0.0) ? $0.1 : nil }
        .joined()

        return KeyboardShortcutDescriptor(
            keyCode: event.keyCode,
            requiredModifierFlags: flags,
            displayLabel: modifierLabel + keyName
        )
    }
}

private final class ShortcutCaptureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var hasClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
}

extension Notification.Name {
    /// Posted while Settings listens for a new key chord, so EchoFlow's own system hotkeys step aside.
    static let echoFlowShortcutCaptureDidBegin = Notification.Name("EchoFlow.shortcutCaptureDidBegin")
    static let echoFlowShortcutCaptureDidEnd = Notification.Name("EchoFlow.shortcutCaptureDidEnd")
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
