import AppKit
import ApplicationServices
import EchoFlowCore
import Observation

/// The primary hotkey can be one of the legacy bare modifier keys or a captured chord.
enum GlobalHotkeySelection: Equatable, Sendable {
    case modifierKey(UInt16)
    case shortcut(KeyboardShortcutDescriptor)
}

private enum GlobalHotkeyInputEvent: Sendable {
    case flagsChanged(keyCode: UInt16, modifierFlags: UInt)
    case keyDown(keyCode: UInt16, modifierFlags: UInt, isRepeat: Bool)
    case keyUp(keyCode: UInt16)

    var diagnosticLabel: String {
        switch self {
        case let .flagsChanged(keyCode, _): "flagsChanged keyCode \(keyCode)"
        case let .keyDown(keyCode, _, isRepeat):
            if isRepeat {
                "keyDown keyCode \(keyCode) repeat"
            } else {
                "keyDown keyCode \(keyCode)"
            }
        case let .keyUp(keyCode): "keyUp keyCode \(keyCode)"
        }
    }
}

@MainActor
@Observable
final class GlobalHotkeyController {
    private(set) var isEnabled = false
    private(set) var hasAccessibilityPermission = AXIsProcessTrusted()
    private(set) var statusMessage = "Global hotkey has not been enabled yet."
    private(set) var receivedKeyboardEventCount = 0
    private(set) var selectedKeyCode: UInt16
    private(set) var selectedHotkey: GlobalHotkeySelection
    private(set) var backupShortcut: KeyboardShortcutDescriptor?
    private(set) var voiceMemoShortcut: KeyboardShortcutDescriptor
    private(set) var rewriteShortcut: KeyboardShortcutDescriptor
    private(set) var selectedMode: ModifierHotkeyMode

    var voiceActionShortcutConflictMessage: String? {
        if KeyboardShortcutConflictPolicy.conflicts(
            voiceMemoShortcut,
            with: [selectedShortcut, backupShortcut],
            reservedModifierFlags: selectedModifierFlags
        ) {
            return "Voice Memo hotkey matches or overlaps the Dictation hotkey. Change one of them to use Voice Memo."
        }
        if KeyboardShortcutConflictPolicy.conflicts(
            rewriteShortcut,
            with: [selectedShortcut, backupShortcut, voiceMemoShortcut],
            reservedModifierFlags: selectedModifierFlags
        ) {
            return "Rewrite hotkey matches or overlaps another EchoFlow hotkey. Change one of them to use Rewrite."
        }
        return nil
    }

    var selectedShortcut: KeyboardShortcutDescriptor? {
        guard case let .shortcut(shortcut) = selectedHotkey else { return nil }
        return shortcut
    }

    private var selectedModifierFlags: KeyboardShortcutModifierFlags {
        guard case let .modifierKey(keyCode) = selectedHotkey else { return [] }
        return switch keyCode {
        case Self.controlKeyCode: .control
        case Self.rightOptionKeyCode: .option
        case Self.functionKeyCode: .function
        default: []
        }
    }

    var onToggleRecording: (@MainActor () -> Void)?
    var onStartRecording: (@MainActor () -> Bool)?
    var onStopRecording: (@MainActor () -> Void)?
    var onStartVoiceMemoRecording: (@MainActor () -> Bool)?
    var onStopVoiceMemoRecording: (@MainActor () -> Void)?
    var onStartVoiceRewriteRecording: (@MainActor () -> Bool)?
    var onStopVoiceRewriteRecording: (@MainActor () -> Void)?
    /// Reports whether a voice action is still starting or recording, so a latch whose
    /// start failed is not left waiting for a stop.
    var isVoiceActionInProgress: (@MainActor (RecordingActionKind) -> Bool)?

    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var recognizer = ModifierTapRecognizer()
    @ObservationIgnored private var shortcutRecognizer: KeyboardShortcutRecognizer?
    @ObservationIgnored private var voiceMemoShortcutRecognizer: KeyboardShortcutRecognizer?
    @ObservationIgnored private var rewriteShortcutRecognizer: KeyboardShortcutRecognizer?
    @ObservationIgnored private var isHoldRecordingActive = false
    @ObservationIgnored private var latchedVoiceAction: RecordingActionKind?
    @ObservationIgnored private let systemHotKeys = SystemHotKeyCenter()
    @ObservationIgnored private var isShortcutCaptureActive = false
    @ObservationIgnored private var shortcutCaptureObservers: [NSObjectProtocol] = []
    private static let voiceMemoHotKeyID: UInt32 = 1
    private static let rewriteHotKeyID: UInt32 = 2
    @ObservationIgnored private var lastKeyboardEventDescription: String?
    @ObservationIgnored private var lastRecognizedAction: String?
    @ObservationIgnored private let defaults: UserDefaults

    private static let keyCodeDefaultsKey = "EchoFlow.globalHotkeyKeyCode"
    private static let modeDefaultsKey = "EchoFlow.globalHotkeyMode"
    private static let selectedShortcutDefaultsKey = "EchoFlow.globalHotkeyShortcut"
    private static let backupShortcutDefaultsKey = "EchoFlow.globalHotkeyBackupShortcut"
    private static let voiceMemoShortcutDefaultsKey = "EchoFlow.voiceMemoShortcut"
    private static let rewriteShortcutDefaultsKey = "EchoFlow.voiceRewriteShortcut"
    private static let defaultVoiceMemoShortcut = KeyboardShortcutDescriptor(
        keyCode: 46,
        requiredModifierFlags: [.command, .shift],
        displayLabel: "⌘⇧M"
    )!
    private static let defaultRewriteShortcut = KeyboardShortcutDescriptor(
        keyCode: 15,
        requiredModifierFlags: [.command, .shift],
        displayLabel: "⌘⇧R"
    )!
    private static let controlKeyCode: UInt16 = 59
    private static let rightOptionKeyCode: UInt16 = 61
    private static let functionKeyCode: UInt16 = 63
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedMode = ModifierHotkeyMode(rawValue: defaults.string(forKey: Self.modeDefaultsKey) ?? "") ?? .tapToToggle

        let savedKeyCode = UInt16(exactly: defaults.integer(forKey: Self.keyCodeDefaultsKey))
        let legacyKeyCode: UInt16
        if let savedKeyCode, Self.isLegacyModifierKey(savedKeyCode) {
            legacyKeyCode = savedKeyCode
        } else {
            legacyKeyCode = Self.controlKeyCode
        }
        let savedShortcut = Self.decodeShortcut(defaults.data(forKey: Self.selectedShortcutDefaultsKey))
            .flatMap { Self.isCustomKeyCode($0.keyCode) ? $0 : nil }

        if let savedShortcut {
            selectedKeyCode = savedShortcut.keyCode
            selectedHotkey = .shortcut(savedShortcut)
        } else {
            selectedKeyCode = legacyKeyCode
            selectedHotkey = .modifierKey(legacyKeyCode)
        }
        backupShortcut = Self.decodeShortcut(defaults.data(forKey: Self.backupShortcutDefaultsKey))
            .flatMap { Self.isCustomKeyCode($0.keyCode) ? $0 : nil }
        voiceMemoShortcut = Self.decodeShortcut(defaults.data(forKey: Self.voiceMemoShortcutDefaultsKey))
            .flatMap { Self.isCustomKeyCode($0.keyCode) ? $0 : nil }
            ?? Self.defaultVoiceMemoShortcut
        rewriteShortcut = Self.decodeShortcut(defaults.data(forKey: Self.rewriteShortcutDefaultsKey))
            .flatMap { Self.isCustomKeyCode($0.keyCode) ? $0 : nil }
            ?? Self.defaultRewriteShortcut

        resetRecognizers()
        observeShortcutCapture()
    }

    /// Voice chords are registered as system hotkeys, which would swallow them while Settings is
    /// capturing a new shortcut, so they are released for the duration of a capture.
    private func observeShortcutCapture() {
        let center = NotificationCenter.default
        shortcutCaptureObservers = [
            center.addObserver(forName: .echoFlowShortcutCaptureDidBegin, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setShortcutCaptureActive(true) }
            },
            center.addObserver(forName: .echoFlowShortcutCaptureDidEnd, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setShortcutCaptureActive(false) }
            }
        ]
    }

    private func setShortcutCaptureActive(_ active: Bool) {
        guard isShortcutCaptureActive != active else { return }
        isShortcutCaptureActive = active
        refreshVoiceActionHotKeys()
    }

    var selectedKeyName: String {
        switch selectedHotkey {
        case let .modifierKey(keyCode):
            Self.modifierKeyName(for: keyCode)
        case let .shortcut(shortcut):
            shortcut.displayLabel ?? "Key code \(shortcut.keyCode)"
        }
    }

    func refreshPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        guard hasAccessibilityPermission else {
            if GlobalHotkeyStatusPolicy.shouldStopHoldRecording(
                accessibilityGranted: hasAccessibilityPermission,
                holdRecordingActive: isHoldRecordingActive
            ) {
                stopActiveHoldIfNeeded()
            }
            stopActiveVoiceActionsIfNeeded()
            removeMonitors()
            isEnabled = false
            resetRecognizers()
            refreshStatusMessage()
            return
        }

        let previouslyEnabled = GlobalHotkeyStatusPolicy.storedEnabledPreference(in: defaults)
        if GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: hasAccessibilityPermission,
            previouslyEnabled: previouslyEnabled
        ), !isEnabled {
            installMonitors()
        } else {
            refreshStatusMessage()
        }
    }

    /// Requests Accessibility permission and opens its System Settings pane.
    func openAccessibilitySettings() {
        if !AXIsProcessTrusted() {
            let promptKey = "AXTrustedCheckOptionPrompt"
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Saves the user's opt-in before prompting for permission, then restores monitoring on return/next launch.
    func requestEnable() {
        GlobalHotkeyStatusPolicy.setEnabledPreference(true, in: defaults)
        refreshPermission()
        if !hasAccessibilityPermission {
            openAccessibilitySettings()
        }
    }

    func chooseKey(keyCode: UInt16) {
        guard Self.isLegacyModifierKey(keyCode) else { return }
        selectedKeyCode = keyCode
        selectedHotkey = .modifierKey(keyCode)
        defaults.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.removeObject(forKey: Self.selectedShortcutDefaultsKey)
        resetRecognizers()
    }

    /// Selects a captured non-modifier key and its required modifier chord.
    @discardableResult
    func chooseCustomShortcut(_ shortcut: KeyboardShortcutDescriptor) -> Bool {
        guard Self.isCustomKeyCode(shortcut.keyCode),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        selectedKeyCode = shortcut.keyCode
        selectedHotkey = .shortcut(shortcut)
        defaults.set(Int(shortcut.keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(data, forKey: Self.selectedShortcutDefaultsKey)
        resetRecognizers()
        return true
    }

    /// Stores or clears the optional backup chord. The same shortcut recognizer handles both keys.
    @discardableResult
    func chooseBackupShortcut(_ shortcut: KeyboardShortcutDescriptor?) -> Bool {
        guard let shortcut else {
            backupShortcut = nil
            defaults.removeObject(forKey: Self.backupShortcutDefaultsKey)
            resetRecognizers()
            return true
        }
        guard Self.isCustomKeyCode(shortcut.keyCode),
              !Self.shortcutsMatch(shortcut, selectedShortcut),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        backupShortcut = shortcut
        defaults.set(data, forKey: Self.backupShortcutDefaultsKey)
        resetRecognizers()
        return true
    }

    /// Stores a tap-to-latch Voice Memo chord distinct from the other configured shortcuts.
    @discardableResult
    func chooseVoiceMemoShortcut(_ shortcut: KeyboardShortcutDescriptor) -> Bool {
        guard Self.isCustomKeyCode(shortcut.keyCode),
              !KeyboardShortcutConflictPolicy.conflicts(
                shortcut,
                with: [selectedShortcut, backupShortcut, rewriteShortcut],
                reservedModifierFlags: selectedModifierFlags
              ),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        voiceMemoShortcut = shortcut
        defaults.set(data, forKey: Self.voiceMemoShortcutDefaultsKey)
        resetVoiceActionRecognizers()
        return true
    }

    /// Stores a tap-to-latch Rewrite chord distinct from the other configured shortcuts.
    @discardableResult
    func chooseRewriteShortcut(_ shortcut: KeyboardShortcutDescriptor) -> Bool {
        guard Self.isCustomKeyCode(shortcut.keyCode),
              !KeyboardShortcutConflictPolicy.conflicts(
                shortcut,
                with: [selectedShortcut, backupShortcut, voiceMemoShortcut],
                reservedModifierFlags: selectedModifierFlags
              ),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        rewriteShortcut = shortcut
        defaults.set(data, forKey: Self.rewriteShortcutDefaultsKey)
        resetVoiceActionRecognizers()
        return true
    }

    func chooseMode(_ mode: ModifierHotkeyMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        resetRecognizers()
    }

    func enable() {
        GlobalHotkeyStatusPolicy.setEnabledPreference(true, in: defaults)
        refreshPermission()
    }

    private func installMonitors() {
        guard hasAccessibilityPermission, !isEnabled else { return }
        receivedKeyboardEventCount = 0
        lastKeyboardEventDescription = nil
        lastRecognizedAction = nil

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let input: GlobalHotkeyInputEvent
            switch event.type {
            case .flagsChanged:
                input = .flagsChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
            case .keyDown:
                input = .keyDown(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags.rawValue,
                    isRepeat: event.isARepeat
                )
            case .keyUp:
                input = .keyUp(keyCode: event.keyCode)
            default:
                return
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handle(input, source: "another app")
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handle(input, source: "another app")
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let input: GlobalHotkeyInputEvent
            switch event.type {
            case .flagsChanged:
                input = .flagsChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
            case .keyDown:
                input = .keyDown(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags.rawValue,
                    isRepeat: event.isARepeat
                )
            case .keyUp:
                input = .keyUp(keyCode: event.keyCode)
            default:
                return event
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handle(input, source: "EchoFlow")
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handle(input, source: "EchoFlow")
                }
            }
            return event
        }

        guard globalMonitor != nil else {
            removeMonitors()
            isEnabled = false
            lastKeyboardEventDescription = "Global keyboard listener registration failed; choose Enable Hotkey to retry."
            refreshStatusMessage()
            return
        }
        isEnabled = true
        refreshVoiceActionHotKeys()
        refreshStatusMessage()
    }

    func disable() {
        GlobalHotkeyStatusPolicy.setEnabledPreference(false, in: defaults)
        removeMonitors()
        isEnabled = false
        stopActiveHoldIfNeeded()
        stopActiveVoiceActionsIfNeeded()
        resetRecognizers()
        lastRecognizedAction = nil
        refreshStatusMessage()
    }

    private func removeMonitors() {
        systemHotKeys.unregisterAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func refreshStatusMessage() {
        statusMessage = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: hasAccessibilityPermission,
            hotkeyEnabledPreference: GlobalHotkeyStatusPolicy.storedEnabledPreference(in: defaults) ?? true,
            globalMonitorInstalled: globalMonitor != nil,
            receivedEventCount: receivedKeyboardEventCount,
            configuredHotkey: "\(selectedKeyName) (\(selectedMode == .tapToToggle ? "tap to toggle" : "hold to talk"))",
            lastEventDescription: lastKeyboardEventDescription,
            lastRecognizedAction: lastRecognizedAction
        )
    }

    private func handle(_ event: GlobalHotkeyInputEvent, source: String) {
        guard isEnabled else { return }
        receivedKeyboardEventCount += 1
        lastKeyboardEventDescription = "\(event.diagnosticLabel) from \(source)"
        lastRecognizedAction = nil
        switch event {
        case let .flagsChanged(keyCode, modifierFlags):
            guard case let .modifierKey(selectedKeyCode) = selectedHotkey,
                  keyCode == selectedKeyCode else { break }
            let flags = NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(.deviceIndependentFlagsMask)
            let targetModifier = Self.modifierFlag(for: selectedKeyCode)
            let hasOtherModifiers = !flags.subtracting(targetModifier).intersection(Self.relevantModifiers).isEmpty
            let isDown = flags.contains(targetModifier)
            dispatch(recognizer.consume(.modifierChanged(isDown: isDown, hasOtherModifiers: hasOtherModifiers)))

        case let .keyDown(keyCode, modifierFlags, isRepeat):
            dispatch(recognizer.consume(.otherKeyDown))
            let flags = Self.shortcutModifierFlags(
                from: NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(.deviceIndependentFlagsMask)
            )
            let keyDownEvent = KeyboardShortcutEvent.keyDown(
                keyCode: keyCode,
                modifierFlags: flags,
                isRepeat: isRepeat
            )
            if var shortcutRecognizer {
                let action = shortcutRecognizer.consume(keyDownEvent)
                self.shortcutRecognizer = shortcutRecognizer
                dispatch(action)
            }
            if var voiceMemoShortcutRecognizer {
                let action = voiceMemoShortcutRecognizer.consume(keyDownEvent)
                self.voiceMemoShortcutRecognizer = voiceMemoShortcutRecognizer
                dispatchVoiceChord(action, for: .voiceMemo)
            }
            if var rewriteShortcutRecognizer {
                let action = rewriteShortcutRecognizer.consume(keyDownEvent)
                self.rewriteShortcutRecognizer = rewriteShortcutRecognizer
                dispatchVoiceChord(action, for: .rewrite)
            }

        case let .keyUp(keyCode):
            let keyUpEvent = KeyboardShortcutEvent.keyUp(keyCode: keyCode)
            if var shortcutRecognizer {
                let action = shortcutRecognizer.consume(keyUpEvent)
                self.shortcutRecognizer = shortcutRecognizer
                dispatch(action)
            }
            if var voiceMemoShortcutRecognizer {
                let action = voiceMemoShortcutRecognizer.consume(keyUpEvent)
                self.voiceMemoShortcutRecognizer = voiceMemoShortcutRecognizer
                dispatchVoiceChord(action, for: .voiceMemo)
            }
            if var rewriteShortcutRecognizer {
                let action = rewriteShortcutRecognizer.consume(keyUpEvent)
                self.rewriteShortcutRecognizer = rewriteShortcutRecognizer
                dispatchVoiceChord(action, for: .rewrite)
            }
        }
        refreshStatusMessage()
    }

    private func resetRecognizers() {
        stopActiveHoldIfNeeded()
        recognizer = ModifierTapRecognizer(mode: selectedMode)
        switch selectedHotkey {
        case .modifierKey:
            if let backupShortcut {
                shortcutRecognizer = KeyboardShortcutRecognizer(primary: backupShortcut, mode: selectedMode)
            } else {
                shortcutRecognizer = nil
            }
        case let .shortcut(shortcut):
            shortcutRecognizer = KeyboardShortcutRecognizer(
                primary: shortcut,
                backup: backupShortcut,
                isBackupEnabled: backupShortcut != nil,
                mode: selectedMode
            )
        }
        resetVoiceActionRecognizers()
        refreshStatusMessage()
    }

    private func resetVoiceActionRecognizers() {
        stopActiveVoiceActionsIfNeeded()
        refreshVoiceActionHotKeys()
    }

    /// Registers each conflict-free voice chord as a system hotkey so the frontmost app never
    /// receives it. If registration is unavailable (listener off, a Settings capture in progress,
    /// an fn chord, or a chord owned by another app), the chord falls back to the passive
    /// keyboard listener, which still works but lets the frontmost app see the keystroke.
    private func refreshVoiceActionHotKeys() {
        systemHotKeys.unregisterAll()
        let voiceMemoAvailable = !KeyboardShortcutConflictPolicy.conflicts(
            voiceMemoShortcut,
            with: [selectedShortcut, backupShortcut, rewriteShortcut],
            reservedModifierFlags: selectedModifierFlags
        )
        let rewriteAvailable = !KeyboardShortcutConflictPolicy.conflicts(
            rewriteShortcut,
            with: [selectedShortcut, backupShortcut, voiceMemoShortcut],
            reservedModifierFlags: selectedModifierFlags
        )
        let canRegister = isEnabled && !isShortcutCaptureActive
        let voiceMemoRegistered = voiceMemoAvailable && canRegister && systemHotKeys.register(
            id: Self.voiceMemoHotKeyID,
            shortcut: voiceMemoShortcut
        ) { [weak self] in
            self?.handleSystemVoiceHotKeyPress(.voiceMemo)
        }
        let rewriteRegistered = rewriteAvailable && canRegister && systemHotKeys.register(
            id: Self.rewriteHotKeyID,
            shortcut: rewriteShortcut
        ) { [weak self] in
            self?.handleSystemVoiceHotKeyPress(.rewrite)
        }
        voiceMemoShortcutRecognizer = voiceMemoAvailable && !voiceMemoRegistered
            ? KeyboardShortcutRecognizer(primary: voiceMemoShortcut, mode: .holdToTalk)
            : nil
        rewriteShortcutRecognizer = rewriteAvailable && !rewriteRegistered
            ? KeyboardShortcutRecognizer(primary: rewriteShortcut, mode: .holdToTalk)
            : nil
        refreshStatusMessage()
    }

    private func handleSystemVoiceHotKeyPress(_ kind: RecordingActionKind) {
        guard isEnabled else { return }
        receivedKeyboardEventCount += 1
        lastKeyboardEventDescription = kind == .voiceMemo ? "Voice Memo hotkey" : "Voice Rewrite hotkey"
        lastRecognizedAction = nil
        handleVoiceChordPress(kind)
    }

    private func stopActiveHoldIfNeeded() {
        guard isHoldRecordingActive else { return }
        isHoldRecordingActive = false
        onStopRecording?()
    }

    private func stopActiveVoiceActionsIfNeeded() {
        guard let latchedVoiceAction else { return }
        stopLatchedVoiceAction(latchedVoiceAction)
    }

    /// Returns the latched voice action, clearing the latch if that action is no longer starting or recording.
    private func validatedLatchedVoiceAction() -> RecordingActionKind? {
        guard let latchedVoiceAction else { return nil }
        guard isVoiceActionInProgress?(latchedVoiceAction) ?? true else {
            self.latchedVoiceAction = nil
            return nil
        }
        return latchedVoiceAction
    }

    /// Voice chords latch: a press starts the action, and the action keeps recording after the
    /// chord is released until the same chord is pressed again or the Dictation hotkey is tapped.
    private func dispatchVoiceChord(_ action: ModifierHotkeyAction?, for kind: RecordingActionKind) {
        // The hold-to-talk recognizer reports a fresh press as .startRecording; releases are ignored.
        guard case .startRecording = action else { return }
        handleVoiceChordPress(kind)
    }

    private func handleVoiceChordPress(_ kind: RecordingActionKind) {
        switch VoiceActionLatchPolicy.voiceChordPressed(kind, latched: validatedLatchedVoiceAction()) {
        case let .start(kind):
            startLatchedVoiceAction(kind)
        case let .stop(kind):
            stopLatchedVoiceAction(kind)
        case .ignore, .passThrough:
            break
        }
        refreshStatusMessage()
    }

    private func startLatchedVoiceAction(_ kind: RecordingActionKind) {
        let started: Bool
        switch kind {
        case .voiceMemo:
            started = onStartVoiceMemoRecording?() == true
        case .rewrite:
            started = onStartVoiceRewriteRecording?() == true
        case .dictation:
            started = false
        }
        guard started else { return }
        latchedVoiceAction = kind
        lastRecognizedAction = kind == .voiceMemo ? "start voice memo" : "start voice rewrite"
    }

    private func stopLatchedVoiceAction(_ kind: RecordingActionKind) {
        guard latchedVoiceAction == kind else { return }
        latchedVoiceAction = nil
        switch kind {
        case .voiceMemo:
            lastRecognizedAction = "stop voice memo"
            onStopVoiceMemoRecording?()
        case .rewrite:
            lastRecognizedAction = "stop voice rewrite"
            onStopVoiceRewriteRecording?()
        case .dictation:
            break
        }
    }

    private func dispatch(_ action: ModifierHotkeyAction?) {
        switch action {
        case .toggleRecording, .startRecording:
            // A latched Voice Memo or Rewrite is stopped by the Dictation hotkey instead of
            // starting dictation. In hold-to-talk mode the matching release is then ignored
            // because no dictation hold was started.
            if case let .stop(kind) = VoiceActionLatchPolicy.dictationHotkeyPressed(
                latched: validatedLatchedVoiceAction()
            ) {
                stopLatchedVoiceAction(kind)
                refreshStatusMessage()
                return
            }
        case .stopRecording, nil:
            break
        }
        switch action {
        case .toggleRecording:
            lastRecognizedAction = "toggle dictation"
            onToggleRecording?()
        case .startRecording:
            guard onStartRecording?() == true else { return }
            lastRecognizedAction = "start dictation"
            isHoldRecordingActive = true
        case .stopRecording:
            guard DictationTogglePolicy.canStopHoldRecording(
                isHoldRecordingActive: isHoldRecordingActive
            ) else { return }
            lastRecognizedAction = "stop dictation"
            isHoldRecordingActive = false
            onStopRecording?()
        case nil:
            break
        }
        refreshStatusMessage()
    }

    private static func decodeShortcut(_ data: Data?) -> KeyboardShortcutDescriptor? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcutDescriptor.self, from: data)
    }

    private static func shortcutsMatch(
        _ left: KeyboardShortcutDescriptor,
        _ right: KeyboardShortcutDescriptor?
    ) -> Bool {
        guard let right else { return false }
        return left.keyCode == right.keyCode
            && left.requiredModifierFlags == right.requiredModifierFlags
    }

    private static func isLegacyModifierKey(_ keyCode: UInt16) -> Bool {
        keyCode == controlKeyCode || keyCode == rightOptionKeyCode || keyCode == functionKeyCode
    }

    private static func isCustomKeyCode(_ keyCode: UInt16) -> Bool {
        !modifierKeyCodes.contains(keyCode)
    }

    private static func modifierKeyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case rightOptionKeyCode: "Right Option"
        case functionKeyCode: "Fn / Globe"
        default: "Left Control"
        }
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case rightOptionKeyCode: .option
        case functionKeyCode: .function
        default: .control
        }
    }

    private static func shortcutModifierFlags(from flags: NSEvent.ModifierFlags) -> KeyboardShortcutModifierFlags {
        var result: KeyboardShortcutModifierFlags = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
