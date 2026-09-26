import AppKit
import ApplicationServices
import CoreGraphics
import EchoFlowCore
import Foundation

@MainActor
final class CapturedInsertionTarget {
    let snapshot: TextInsertionSnapshot
    let focusedElement: AXUIElement

    init(snapshot: TextInsertionSnapshot, focusedElement: AXUIElement) {
        self.snapshot = snapshot
        self.focusedElement = focusedElement
    }
}

@MainActor
final class CapturedRewriteSelection {
    let snapshot: RewriteSelectionSnapshot
    let focusedElement: AXUIElement

    init(snapshot: RewriteSelectionSnapshot, focusedElement: AXUIElement) {
        self.snapshot = snapshot
        self.focusedElement = focusedElement
    }
}

enum RewriteSelectionReplacementOutcome {
    case replacedByAccessibility
    case insertedByKeyboardEvents
    case selectionChanged
    case targetUnavailable
    case failed
}

@MainActor
final class CapturedDeliveryTarget {
    let snapshot: TextInsertionSnapshot
    let accessibilityTarget: CapturedInsertionTarget?
    let focusedElementType: String

    init(
        snapshot: TextInsertionSnapshot,
        accessibilityTarget: CapturedInsertionTarget?,
        focusedElementType: String
    ) {
        self.snapshot = snapshot
        self.accessibilityTarget = accessibilityTarget
        self.focusedElementType = focusedElementType
    }
}

@MainActor
final class TextInsertionService {
    enum Outcome {
        case inserted
        case insertedViaKeyboardEvents
        case insertedAndSubmitted
        case blocked(TextInsertionBlockReason)
        case failed
    }

    struct DeliveryReport {
        let outcome: Outcome
        let debugInfo: String

        var textWasInserted: Bool {
            switch outcome {
            case .inserted, .insertedViaKeyboardEvents, .insertedAndSubmitted:
                true
            case .blocked, .failed:
                false
            }
        }

        var needsDeliveryNotice: Bool { !textWasInserted }
    }

    private struct CorrectionInsertionContext {
        let scope: InsertedTextCorrectionScope
        let originalFieldCharacterCount: Int
        let originalSelection: InsertedTextCorrectionRange
    }

    private struct PendingCorrectionSelection {
        let candidate: InsertedTextCorrectionCandidate
        let generation: UInt64
    }

    private struct CorrectionObservationSession {
        let target: CapturedInsertionTarget
        let scope: InsertedTextCorrectionScope
        let deadline: ContinuousClock.Instant
        var pendingSelection: PendingCorrectionSelection?
        var selectionGeneration: UInt64 = 0
    }

    private let defaults: UserDefaults
    private var correctionSession: CorrectionObservationSession?
    /// Result of the last AXManualAccessibility request per process, shown in delivery diagnostics.
    private var manualAccessibilityResults: [pid_t: AXError] = [:]
    private var correctionObserver: AXObserver?
    private var correctionRunLoopSource: CFRunLoopSource?
    private var correctionObserverRetain: Unmanaged<TextInsertionService>?
    private var correctionLifetimeTask: Task<Void, Never>?
    private var correctionDebounceTask: Task<Void, Never>?

    static let correctionLearningPreferenceKey = "EchoFlow.learnRecentInsertionCorrections"

    var onTranscriptCorrection: ((String, String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func captureTarget() -> CapturedInsertionTarget? {
        captureFocusedTarget()
    }

    func captureRewriteSelection() -> Result<CapturedRewriteSelection, RewriteSelectionDecision> {
        guard let excludedBundleIdentifiers = additionalExcludedBundleIdentifiers else {
            return .failure(.policyUnavailable)
        }
        guard let target = captureFocusedTarget(requireFrontmostProcessMatch: true) else {
            return .failure(.unsupportedField)
        }
        if let decision = RewriteSelectionPolicy.targetDecision(
            for: target.snapshot,
            additionalExcludedBundleIdentifiers: excludedBundleIdentifiers
        ) {
            return .failure(decision)
        }
        guard let selectionSnapshot = rewriteSelectionSnapshot(for: target) else {
            return .failure(.noSelection)
        }
        let decision = RewriteSelectionPolicy.captureDecision(
            for: selectionSnapshot,
            additionalExcludedBundleIdentifiers: additionalExcludedBundleIdentifiers
        )
        guard decision == .allowed else { return .failure(decision) }
        return .success(CapturedRewriteSelection(snapshot: selectionSnapshot, focusedElement: target.focusedElement))
    }

    func replaceSelectedText(
        with text: String,
        captured: CapturedRewriteSelection
    ) async -> RewriteSelectionReplacementOutcome {
        guard let rewrittenText = VoiceRewritePolicy.validOutput(text) else { return .failed }
        guard rewriteSelectionStillMatches(captured) else { return .selectionChanged }

        if AXUIElementSetAttributeValue(
            captured.focusedElement,
            kAXSelectedTextAttribute as CFString,
            rewrittenText as CFString
        ) == .success {
            return .replacedByAccessibility
        }

        guard rewriteSelectionStillMatches(captured) else { return .selectionChanged }
        guard postUnicodeText(
            rewrittenText,
            to: captured.snapshot.target.processIdentifier
        ) else { return .failed }
        return .insertedByKeyboardEvents
    }

    func captureDeliveryTarget() -> CapturedDeliveryTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let accessibilityTarget = captureFocusedTarget().flatMap { target in
            target.snapshot.processIdentifier == application.processIdentifier ? target : nil
        }
        let snapshot = accessibilityTarget?.snapshot ?? TextInsertionSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            focusedRole: nil,
            applicationName: application.localizedName
        )
        let focusedElementType: String
        if let role = snapshot.focusedRole {
            if let subrole = snapshot.focusedSubrole, subrole != role {
                focusedElementType = "\(role) / \(subrole)"
            } else {
                focusedElementType = role
            }
        } else if !AXIsProcessTrusted() {
            focusedElementType = "Unavailable (Accessibility permission not granted)"
        } else {
            focusedElementType = "Unavailable (Accessibility API did not expose the focused element)"
        }
        return CapturedDeliveryTarget(
            snapshot: snapshot,
            accessibilityTarget: accessibilityTarget,
            focusedElementType: focusedElementType
        )
    }

    /// Electron apps such as Claude, Slack, and VS Code keep their accessibility tree off until a
    /// client sets AXManualAccessibility on the application, so their focused text field is not
    /// exposed and insertion fails closed. Call this when recording starts so the tree is ready by
    /// the time the transcript is delivered. Excluded apps are left untouched; other apps ignore it.
    func prepareFrontmostAppAccessibility() {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              !isExcludedOrUnverifiable(application.bundleIdentifier) else { return }
        enableManualAccessibility(for: application.processIdentifier)
    }

    private func enableManualAccessibility(for processIdentifier: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let result = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        manualAccessibilityResults[processIdentifier] = result
    }

    /// Reads the field's length and caret so an Accessibility insertion can be verified.
    private func accessibilityEditState(of element: AXUIElement) -> AccessibilityEditState {
        AccessibilityEditState(
            characterCount: accessibilityCharacterCount(of: element),
            selectedRange: accessibilityRange(kAXSelectedTextRangeAttribute, of: element)
        )
    }

    /// Waits briefly for the field to reflect an Accessibility insertion. Fields that expose
    /// neither length nor caret cannot be checked, so their reported success is kept.
    private func accessibilityInsertionTookEffect(
        in element: AXUIElement,
        before: AccessibilityEditState
    ) async -> Bool {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            switch AccessibilityInsertionVerification.check(before: before, after: accessibilityEditState(of: element)) {
            case .changed, .unverifiable:
                return true
            case .unchanged:
                continue
            }
        }
        return false
    }

    func isFrontmostAppExcluded() -> Bool {
        isExcludedOrUnverifiable(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func isFrontmostAppExcludedForVoiceAction() -> Bool {
        isFrontmostAppExcluded()
    }

    func setCorrectionLearningEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.correctionLearningPreferenceKey)
        if !enabled { stopCorrectionObservation() }
    }

    func cancelCorrectionObservationIfTargetIsInvalid() {
        guard let session = correctionSession else { return }
        guard isCorrectionObservationOpen(session), isCorrectionTargetValid(session.target) else {
            stopCorrectionObservation()
            return
        }
    }

    func deliver(
        _ text: String,
        capturedTarget: CapturedDeliveryTarget?,
        autoSend: Bool
    ) async -> DeliveryReport {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return DeliveryReport(
                outcome: .failed,
                debugInfo: diagnosticInfo(
                    captured: capturedTarget,
                    current: nil,
                    insertionResult: "Transcript was empty; there was no text to insert."
                )
            )
        }

        stopCorrectionObservation()
        let current = captureDeliveryTarget()
        let sameFocusedElement = Self.isSameFocusedElement(capturedTarget, current)
        let decision = decisionUsingCurrentPolicy(
            captured: capturedTarget?.snapshot,
            current: current?.snapshot,
            sameFocusedElement: sameFocusedElement
        )
        if case let .blocked(reason) = decision {
            return DeliveryReport(
                outcome: .blocked(reason),
                debugInfo: diagnosticInfo(
                    captured: capturedTarget,
                    current: current,
                    insertionResult: explanation(for: reason)
                )
            )
        }

        // Revalidate immediately before touching the selected field; text is never staged on NSPasteboard.
        let targetAtInsertion = captureDeliveryTarget()
        let sameFocusAtInsertion = Self.isSameFocusedElement(capturedTarget, targetAtInsertion)
        let finalDecision = decisionUsingCurrentPolicy(
            captured: capturedTarget?.snapshot,
            current: targetAtInsertion?.snapshot,
            sameFocusedElement: sameFocusAtInsertion
        )
        if case let .blocked(reason) = finalDecision {
            return DeliveryReport(
                outcome: .blocked(reason),
                debugInfo: diagnosticInfo(
                    captured: capturedTarget,
                    current: targetAtInsertion,
                    insertionResult: explanation(for: reason)
                )
            )
        }
        guard let targetAtInsertion else {
            return DeliveryReport(
                outcome: .failed,
                debugInfo: diagnosticInfo(
                    captured: capturedTarget,
                    current: nil,
                    insertionResult: "EchoFlow could not verify the target application before text input."
                )
            )
        }

        let correctionInsertion = finalDecision == .insert
                && defaults.bool(forKey: Self.correctionLearningPreferenceKey)
            ? correctionInsertionContext(for: cleanText, target: targetAtInsertion.accessibilityTarget)
            : nil

        var insertedByAccessibility = false
        var accessibilityInsertionNote: String?
        if finalDecision == .insert,
           let accessibilityTarget = targetAtInsertion.accessibilityTarget {
            let element = accessibilityTarget.focusedElement
            let stateBeforeInsertion = accessibilityEditState(of: element)
            let setResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                cleanText as CFString
            )
            if setResult == .success {
                // Chromium and Electron fields can report success without changing; only count
                // the insertion once the field's length or caret actually moves.
                insertedByAccessibility = await accessibilityInsertionTookEffect(
                    in: element,
                    before: stateBeforeInsertion
                )
                if !insertedByAccessibility {
                    accessibilityInsertionNote = "Accessibility accepted the text but the field did not change, so Unicode keyboard input was used instead."
                }
            } else {
                accessibilityInsertionNote = "Accessibility could not set the selected text (AXError \(setResult.rawValue)), so Unicode keyboard input was used instead."
            }
        }

        if !insertedByAccessibility {
            guard let keyboardTarget = captureDeliveryTarget() else {
                return DeliveryReport(
                    outcome: .blocked(.targetUnavailable),
                    debugInfo: diagnosticInfo(
                        captured: capturedTarget,
                        current: nil,
                        insertionResult: "The foreground app could not be verified immediately before Unicode text input."
                    )
                )
            }
            let keyboardDecision = decisionUsingCurrentPolicy(
                captured: targetAtInsertion.snapshot,
                current: keyboardTarget.snapshot,
                sameFocusedElement: Self.isSameFocusedElement(targetAtInsertion, keyboardTarget)
            )
            if case let .blocked(reason) = keyboardDecision {
                return DeliveryReport(
                    outcome: .blocked(reason),
                    debugInfo: diagnosticInfo(
                        captured: capturedTarget,
                        current: keyboardTarget,
                        insertionResult: explanation(for: reason)
                    )
                )
            }
            guard keyboardTarget.snapshot.processIdentifier == targetAtInsertion.snapshot.processIdentifier else {
                return DeliveryReport(
                    outcome: .blocked(.targetChanged),
                    debugInfo: diagnosticInfo(
                        captured: capturedTarget,
                        current: keyboardTarget,
                        insertionResult: "The target app restarted before Unicode text input."
                    )
                )
            }
            guard postUnicodeText(cleanText, to: keyboardTarget.snapshot.processIdentifier) else {
                return DeliveryReport(
                    outcome: .failed,
                    debugInfo: diagnosticInfo(
                        captured: capturedTarget,
                        current: keyboardTarget,
                        insertionResult: "macOS did not accept Unicode text input for the verified target."
                    )
                )
            }
        }

        let verifiedAXTarget = finalDecision == .insert ? targetAtInsertion.accessibilityTarget : nil
        let correctionDeadline = ContinuousClock().now.advanced(by: .seconds(10))
        if let correctionInsertion, let verifiedAXTarget {
            try? await Task.sleep(for: .milliseconds(100))
            startCorrectionObservation(
                correctionInsertion,
                target: verifiedAXTarget,
                deadline: correctionDeadline
            )
        }

        var submitted = false
        if TextInsertionPolicy.canSubmitAfterInsertion(
            autoSendEnabled: autoSend,
            insertionConfirmedByAccessibility: insertedByAccessibility
        ), let verifiedAXTarget {
            try? await Task.sleep(for: .milliseconds(140))
            if sameTargetIsStillFocused(capturedTarget?.accessibilityTarget) {
                submitted = postKey(
                    virtualKey: 36,
                    command: false,
                    to: verifiedAXTarget.snapshot.processIdentifier
                )
            }
        }
        if submitted { stopCorrectionObservation() }

        let usedKeyboardFallback = !insertedByAccessibility
        let outcome: Outcome = if submitted {
            .insertedAndSubmitted
        } else if usedKeyboardFallback {
            .insertedViaKeyboardEvents
        } else {
            .inserted
        }
        let insertionResult = usedKeyboardFallback
            ? [accessibilityInsertionNote, "Unicode keyboard input was sent to the same foreground application; app acceptance cannot be confirmed."]
                .compactMap { $0 }
                .joined(separator: " ")
            : "Accessibility inserted text into the verified field."
        return DeliveryReport(
            outcome: outcome,
            debugInfo: diagnosticInfo(
                captured: capturedTarget,
                current: targetAtInsertion,
                insertionResult: submitted ? "Text was inserted and Return was sent." : insertionResult
            )
        )
    }

    private static func isSameFocusedElement(
        _ captured: CapturedDeliveryTarget?,
        _ current: CapturedDeliveryTarget?
    ) -> Bool {
        guard let capturedElement = captured?.accessibilityTarget?.focusedElement,
              let currentElement = current?.accessibilityTarget?.focusedElement else {
            return false
        }
        return CFEqual(capturedElement, currentElement)
    }

    private func diagnosticInfo(
        captured: CapturedDeliveryTarget?,
        current: CapturedDeliveryTarget?,
        insertionResult: String
    ) -> String {
        let stoppedApp = captured?.snapshot.applicationName ?? "Unknown"
        let readyApp = current?.snapshot.applicationName ?? "Unknown"
        let stoppedFocusType = captured?.focusedElementType ?? "Unavailable (no frontmost application)"
        var readyFocusType = current?.focusedElementType ?? "Unavailable (no frontmost application)"
        if let processIdentifier = current?.snapshot.processIdentifier,
           let result = manualAccessibilityResults[processIdentifier] {
            readyFocusType += result == .success
                ? " (app accessibility enabled)"
                : " (app did not accept AXManualAccessibility, AXError \(result.rawValue))"
        }
        return TextInsertionDiagnostic(
            appAtDictationStop: stoppedApp,
            appWhenTextWasReady: readyApp,
            focusedElementAtStop: stoppedFocusType,
            focusedElementWhenReady: readyFocusType,
            insertionResult: insertionResult
        ).description
    }

    private func explanation(for reason: TextInsertionBlockReason) -> String {
        switch reason {
        case .targetUnavailable:
            "The frontmost app could not be verified at dictation stop or delivery time."
        case .targetChanged:
            "The frontmost app changed between dictation stop and text insertion."
        case .secureField:
            "The focused field is marked as secure, so text input is disabled."
        case .unsupportedField:
            "The focused control could not be verified as a text field, so text input was blocked."
        case .policyUnavailable:
            "EchoFlow could not verify the excluded-app policy or app identity, so text input was blocked."
        case .excludedApplication:
            "The frontmost app is excluded by EchoFlow's app policy."
        }
    }

    private func sameTargetIsStillFocused(_ captured: CapturedInsertionTarget?) -> Bool {
        guard let captured, let current = captureFocusedTarget() else { return false }
        guard CFEqual(captured.focusedElement, current.focusedElement) else { return false }
        return decisionUsingCurrentPolicy(
            captured: captured.snapshot,
            current: current.snapshot,
            sameFocusedElement: true
        ) == .insert
    }

    private func correctionInsertionContext(
        for text: String,
        target: CapturedInsertionTarget?
    ) -> CorrectionInsertionContext? {
        guard let target,
              isCorrectionTargetValid(target),
              let selection = accessibilityRange(kAXSelectedTextRangeAttribute, of: target.focusedElement),
              let fieldCharacterCount = accessibilityCharacterCount(of: target.focusedElement),
              let selectionEnd = selection.upperBound,
              selectionEnd <= fieldCharacterCount,
              let scope = InsertedTextCorrectionScope(
                insertedText: text,
                insertionLocation: selection.location
              ) else {
            return nil
        }
        return CorrectionInsertionContext(
            scope: scope,
            originalFieldCharacterCount: fieldCharacterCount,
            originalSelection: selection
        )
    }

    private func startCorrectionObservation(
        _ insertion: CorrectionInsertionContext,
        target: CapturedInsertionTarget,
        deadline: ContinuousClock.Instant
    ) {
        guard defaults.bool(forKey: Self.correctionLearningPreferenceKey),
              ContinuousClock().now < deadline,
              isCorrectionTargetValid(target),
              let postInsertionCount = accessibilityCharacterCount(of: target.focusedElement),
              let postInsertionSelection = accessibilityRange(
                kAXSelectedTextRangeAttribute,
                of: target.focusedElement
              ),
              postInsertionSelection.length == 0 else {
            return
        }

        let (remainingCharacterCount, subtractionOverflow) = insertion.originalFieldCharacterCount
            .subtractingReportingOverflow(insertion.originalSelection.length)
        let (expectedCharacterCount, additionOverflow) = remainingCharacterCount
            .addingReportingOverflow(insertion.scope.insertedText.utf16.count)
        let (expectedCaretLocation, caretOverflow) = insertion.scope.insertionLocation
            .addingReportingOverflow(insertion.scope.insertedText.utf16.count)
        guard !subtractionOverflow,
              !additionOverflow,
              !caretOverflow,
              postInsertionCount == expectedCharacterCount,
              postInsertionSelection.location == expectedCaretLocation,
              let insertedRange = InsertedTextCorrectionRange(
                location: insertion.scope.insertionLocation,
                length: insertion.scope.insertedText.utf16.count
              ),
              let insertedCandidate = insertion.scope.candidate(
                for: insertedRange,
                fieldCharacterCount: postInsertionCount
              ),
              insertedCandidate.originalText == insertion.scope.insertedText else {
            return
        }

        // Keep the C callback target alive until notifications and the run-loop source are removed.
        let retainedService = Unmanaged.passRetained(self)
        var observer: AXObserver?
        guard AXObserverCreate(target.snapshot.processIdentifier, echoFlowCorrectionObserverCallback, &observer)
                == .success,
              let observer else {
            retainedService.release()
            return
        }

        let context = retainedService.toOpaque()
        guard AXObserverAddNotification(
            observer,
            target.focusedElement,
            kAXSelectedTextChangedNotification as CFString,
            context
        ) == .success else {
            retainedService.release()
            return
        }
        guard AXObserverAddNotification(
            observer,
            target.focusedElement,
            kAXValueChangedNotification as CFString,
            context
        ) == .success else {
            _ = AXObserverRemoveNotification(
                observer,
                target.focusedElement,
                kAXSelectedTextChangedNotification as CFString
            )
            retainedService.release()
            return
        }

        correctionSession = CorrectionObservationSession(
            target: target,
            scope: insertion.scope,
            deadline: deadline
        )
        correctionObserver = observer
        correctionObserverRetain = retainedService
        let source = AXObserverGetRunLoopSource(observer)
        correctionRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        startCorrectionLifetimeTask(deadline: deadline)
    }

    fileprivate func receiveCorrectionAXNotification(notificationName: String) {
        guard var session = correctionSession else { return }
        guard isCorrectionObservationOpen(session) else {
            stopCorrectionObservation()
            return
        }
        guard isCorrectionTargetValid(session.target) else {
            stopCorrectionObservation()
            return
        }

        if notificationName == (kAXSelectedTextChangedNotification as String) {
            guard let selection = accessibilityRange(
                    kAXSelectedTextRangeAttribute,
                    of: session.target.focusedElement
                  ),
                  let fieldCharacterCount = accessibilityCharacterCount(of: session.target.focusedElement) else {
                stopCorrectionObservation()
                return
            }

            session.selectionGeneration &+= 1
            if selection.length == 0 {
                if correctionDebounceTask == nil {
                    session.pendingSelection = nil
                }
                correctionSession = session
                return
            }

            guard let candidate = session.scope.candidate(
                for: selection,
                fieldCharacterCount: fieldCharacterCount
            ) else {
                correctionDebounceTask?.cancel()
                correctionDebounceTask = nil
                session.pendingSelection = nil
                correctionSession = session
                return
            }

            correctionDebounceTask?.cancel()
            correctionDebounceTask = nil
            session.pendingSelection = PendingCorrectionSelection(
                candidate: candidate,
                generation: session.selectionGeneration
            )
            correctionSession = session
            return
        }

        guard notificationName == (kAXValueChangedNotification as String),
              let pendingSelection = session.pendingSelection else {
            return
        }
        correctionDebounceTask?.cancel()
        let generation = pendingSelection.generation
        correctionDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.attemptCorrection(generation: generation)
        }
    }

    private func attemptCorrection(generation: UInt64) {
        correctionDebounceTask = nil
        guard var session = correctionSession,
              let pendingSelection = session.pendingSelection,
              pendingSelection.generation == generation else {
            return
        }
        guard isCorrectionObservationOpen(session) else {
            stopCorrectionObservation()
            return
        }

        session.pendingSelection = nil
        correctionSession = session
        let target = session.target
        guard isCorrectionTargetValid(target),
              let fieldCharacterCount = accessibilityCharacterCount(of: target.focusedElement),
              let caret = accessibilityRange(kAXSelectedTextRangeAttribute, of: target.focusedElement) else {
            stopCorrectionObservation()
            return
        }
        guard caret.length == 0,
              let replacementRange = session.scope.replacementRange(
                for: pendingSelection.candidate,
                currentFieldCharacterCount: fieldCharacterCount,
                caretLocation: caret.location
              ),
              session.scope.candidate(
                for: replacementRange,
                fieldCharacterCount: fieldCharacterCount
              ) != nil,
              isCorrectionTargetValid(target),
              let correctedText = accessibilityString(
                for: replacementRange,
                of: target.focusedElement
              ),
              (correctedText as NSString).length == replacementRange.length,
              isCorrectionObservationOpen(session),
              isCorrectionTargetValid(target) else {
            return
        }

        let corrections = TranscriptCorrectionExtractor.extract(
            from: pendingSelection.candidate.originalText,
            to: correctedText
        )
        for correction in corrections {
            guard let activeSession = correctionSession,
                  isCorrectionObservationOpen(activeSession),
                  isCorrectionTargetValid(target) else {
                stopCorrectionObservation()
                return
            }
            onTranscriptCorrection?(correction.original, correction.replacement)
        }
    }

    private func isCorrectionObservationOpen(_ session: CorrectionObservationSession) -> Bool {
        CorrectionObservationDeadlinePolicy.isOpen(deadline: session.deadline, now: ContinuousClock().now)
    }

    private func startCorrectionLifetimeTask(deadline: ContinuousClock.Instant) {
        correctionLifetimeTask?.cancel()
        correctionLifetimeTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled, clock.now < deadline {
                guard let self else { return }
                guard self.isCorrectionTargetValid() else {
                    self.stopCorrectionObservation()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.stopCorrectionObservation()
        }
    }

    private func isCorrectionTargetValid(_ target: CapturedInsertionTarget? = nil) -> Bool {
        guard defaults.bool(forKey: Self.correctionLearningPreferenceKey),
              AXIsProcessTrusted(),
              let expectedTarget = target ?? correctionSession?.target,
              let expectedBundleIdentifier = expectedTarget.snapshot.bundleIdentifier,
              let application = NSWorkspace.shared.frontmostApplication,
              let applicationBundleIdentifier = application.bundleIdentifier,
              application.processIdentifier == expectedTarget.snapshot.processIdentifier,
              applicationBundleIdentifier == expectedBundleIdentifier,
              !isExcludedOrUnverifiable(applicationBundleIdentifier),
              let current = captureFocusedTarget(),
              CFEqual(expectedTarget.focusedElement, current.focusedElement),
              current.snapshot.processIdentifier == expectedTarget.snapshot.processIdentifier,
              current.snapshot.bundleIdentifier == expectedBundleIdentifier,
              let role = current.snapshot.focusedRole,
              let subrole = current.snapshot.focusedSubrole,
              ["AXTextField", "AXTextArea", "AXSearchField"].contains(role),
              role != "AXSecureTextField",
              subrole != "AXSecureTextField",
              !isExcludedOrUnverifiable(current.snapshot.bundleIdentifier) else {
            return false
        }
        return true
    }

    private func stopCorrectionObservation() {
        correctionDebounceTask?.cancel()
        correctionDebounceTask = nil
        correctionLifetimeTask?.cancel()
        correctionLifetimeTask = nil

        let session = correctionSession
        correctionSession = nil
        if let observer = correctionObserver, let element = session?.target.focusedElement {
            _ = AXObserverRemoveNotification(
                observer,
                element,
                kAXSelectedTextChangedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                observer,
                element,
                kAXValueChangedNotification as CFString
            )
        }
        if let source = correctionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        correctionObserver = nil
        correctionRunLoopSource = nil
        correctionObserverRetain?.release()
        correctionObserverRetain = nil
    }

    private func captureFocusedTarget(requireFrontmostProcessMatch: Bool = true) -> CapturedInsertionTarget? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) != .success
            || focusedValue == nil {
            // Electron apps expose nothing system-wide until their accessibility tree is enabled;
            // enable it (never for excluded apps) and ask the frontmost application directly.
            guard !isExcludedOrUnverifiable(application.bundleIdentifier) else { return nil }
            enableManualAccessibility(for: application.processIdentifier)
            focusedValue = nil
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            guard AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            ) == .success else { return nil }
        }
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = focusedValue as! AXUIElement
        if requireFrontmostProcessMatch {
            var focusedProcessIdentifier: pid_t = 0
            guard AXUIElementGetPid(focusedElement, &focusedProcessIdentifier) == .success,
                  focusedProcessIdentifier == application.processIdentifier else {
                return nil
            }
        }

        let role = accessibilityAttributeString(kAXRoleAttribute, of: focusedElement)
        let subrole = accessibilityAttributeString(kAXSubroleAttribute, of: focusedElement)
        let snapshot = TextInsertionSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            focusedRole: role,
            focusedSubrole: subrole,
            applicationName: application.localizedName,
            focusedElementIsEditable: accessibilityAttributeBoolean(kAXIsEditableAttribute, of: focusedElement)
        )
        return CapturedInsertionTarget(snapshot: snapshot, focusedElement: focusedElement)
    }

    private func rewriteSelectionSnapshot(for target: CapturedInsertionTarget) -> RewriteSelectionSnapshot? {
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target.focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
              let selectedValue,
              let selectedText = selectedValue as? String,
              let selectedRange = accessibilityRange(kAXSelectedTextRangeAttribute, of: target.focusedElement),
              let fieldCharacterCount = accessibilityCharacterCount(of: target.focusedElement),
              selectedRange.length > 0 else {
            return nil
        }
        return RewriteSelectionSnapshot(
            target: target.snapshot,
            selectedText: selectedText,
            rangeLocation: selectedRange.location,
            rangeLength: selectedRange.length,
            fieldCharacterCount: fieldCharacterCount
        )
    }

    private func rewriteSelectionStillMatches(_ captured: CapturedRewriteSelection) -> Bool {
        guard let excludedBundleIdentifiers = additionalExcludedBundleIdentifiers,
              let currentTarget = captureFocusedTarget(requireFrontmostProcessMatch: true),
              CFEqual(captured.focusedElement, currentTarget.focusedElement),
              RewriteSelectionPolicy.targetDecision(
                for: currentTarget.snapshot,
                additionalExcludedBundleIdentifiers: excludedBundleIdentifiers
              ) == nil,
              let currentSelection = rewriteSelectionSnapshot(for: currentTarget) else {
            return false
        }
        return RewriteSelectionPolicy.canReplace(
            captured: captured.snapshot,
            current: currentSelection,
            sameFocusedElement: true,
            additionalExcludedBundleIdentifiers: excludedBundleIdentifiers
        )
    }

    private var additionalExcludedBundleIdentifiers: Set<String>? {
        guard let policy = ExcludedAppPolicy.resolvePersisted(
            defaults.data(forKey: ExcludedApplicationsViewModel.defaultsKey)
        ) else { return nil }
        return Set(
            (policy.defaultExcludedApplications + policy.userExcludedApplications)
                .map(\.bundleIdentifier)
        )
    }

    private var currentPolicy: TextInsertionPolicy? {
        guard let identifiers = additionalExcludedBundleIdentifiers else { return nil }
        return TextInsertionPolicy(excludedBundleIdentifiers: identifiers)
    }

    private func isExcludedOrUnverifiable(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let currentPolicy else {
            return true
        }
        return currentPolicy.isExcluded(bundleIdentifier: bundleIdentifier)
    }

    private func decisionUsingCurrentPolicy(
        captured: TextInsertionSnapshot?,
        current: TextInsertionSnapshot?,
        sameFocusedElement: Bool
    ) -> TextInsertionDecision {
        guard let currentPolicy else { return .blocked(.policyUnavailable) }
        return currentPolicy.decision(
            captured: captured,
            current: current,
            sameFocusedElement: sameFocusedElement
        )
    }

    private func accessibilityAttributeString(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func accessibilityAttributeBoolean(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    private func accessibilityRange(
        _ attribute: String,
        of element: AXUIElement
    ) -> InsertedTextCorrectionRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return InsertedTextCorrectionRange(location: range.location, length: range.length)
    }

    private func accessibilityCharacterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let count = number.intValue
        return count >= 0 ? count : nil
    }

    private func accessibilityString(
        for range: InsertedTextCorrectionRange,
        of element: AXUIElement
    ) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success,
              let value else {
            return nil
        }
        return value as? String
    }

    private func postUnicodeText(_ text: String, to processIdentifier: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              processIdentifier > 0,
              let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        let chunks = KeyboardTextEventPolicy.unicodeChunks(for: text)
        guard !chunks.isEmpty else { return false }

        // An unmapped keycode ensures apps that ignore the Unicode field do not receive a
        // different printable character through ordinary keyboard-layout translation.
        let unmappedKeyCode = CGKeyCode.max
        var events: [(down: CGEvent, up: CGEvent)] = []
        for chunk in chunks {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: unmappedKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: unmappedKeyCode, keyDown: false) else {
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
            }
            events.append((down: keyDown, up: keyUp))
        }
        for eventPair in events {
            eventPair.down.postToPid(processIdentifier)
            eventPair.up.postToPid(processIdentifier)
        }
        return true
    }

    private func postKey(virtualKey: CGKeyCode, command: Bool, to processIdentifier: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              processIdentifier > 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        if command {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
        }
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}

private func echoFlowCorrectionObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard Thread.isMainThread, let refcon else { return }
    let service = Unmanaged<TextInsertionService>.fromOpaque(refcon).takeUnretainedValue()
    let notificationName = notification as String
    MainActor.assumeIsolated {
        service.receiveCorrectionAXNotification(notificationName: notificationName)
    }
}
