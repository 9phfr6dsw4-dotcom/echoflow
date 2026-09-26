import AppKit
import EchoFlowCore
import Foundation
import Observation

@MainActor
@Observable
final class RecordingFeedbackController {
    static let dockIconPreferenceKey = "EchoFlow.changeDockIconWhileRecording"
    static let soundsPreferenceKey = "EchoFlow.playRecordingSounds"
    static let soundVolumePreferenceKey = "EchoFlow.recordingSoundVolume"

    private(set) var isRecording = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isShowingRecordingDockIcon = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordingStarted() {
        guard !isRecording else { return }
        isRecording = true
        if defaults.bool(forKey: Self.dockIconPreferenceKey) {
            applyRecordingDockIcon()
        }
        if defaults.bool(forKey: Self.soundsPreferenceKey) {
            playSound(named: "Tink")
        }
    }

    func recordingStopped() {
        guard isRecording else { return }
        isRecording = false
        restoreDockIcon()
        if defaults.bool(forKey: Self.soundsPreferenceKey) {
            // The same soft sound as the start cue; the sharper "Pop" was unwelcome at stop.
            playSound(named: "Tink")
        }
    }

    func setDockIconChangeEnabled(_ enabled: Bool) {
        guard isRecording else { return }
        if enabled {
            applyRecordingDockIcon()
        } else {
            restoreDockIcon()
        }
    }

    private func applyRecordingDockIcon() {
        guard !isShowingRecordingDockIcon else { return }
        let application = NSApplication.shared
        // Draw from a copy: the getter returns AppKit's shared application icon, which takes on
        // the badged image once it is set, so it cannot be saved and put back later.
        guard let original = application.applicationIconImage?.copy() as? NSImage else { return }
        isShowingRecordingDockIcon = true

        let image = NSImage(size: original.size)
        image.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: original.size))
        let badgeSize = min(original.size.width, original.size.height) * 0.34
        let badgeRect = NSRect(
            x: original.size.width - badgeSize,
            y: 0,
            width: badgeSize,
            height: badgeSize
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        NSColor.white.setStroke()
        let waveform = NSBezierPath()
        waveform.lineWidth = max(1.5, badgeSize * 0.11)
        waveform.lineCapStyle = .round
        let centerY = badgeRect.midY
        waveform.move(to: NSPoint(x: badgeRect.minX + badgeSize * 0.28, y: centerY))
        waveform.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.42, y: centerY - badgeSize * 0.18))
        waveform.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.55, y: centerY + badgeSize * 0.18))
        waveform.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.70, y: centerY))
        waveform.stroke()
        image.unlockFocus()
        application.applicationIconImage = image
    }

    private func restoreDockIcon() {
        guard isShowingRecordingDockIcon else { return }
        isShowingRecordingDockIcon = false
        // nil restores the bundle's AppIcon.icns.
        NSApplication.shared.applicationIconImage = nil
    }

    private func playSound(named name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        let storedVolume = defaults.object(forKey: Self.soundVolumePreferenceKey) as? Double
        sound.volume = Float(RecordingSoundVolumePolicy.normalizedLevel(storedValue: storedVolume))
        sound.play()
    }
}
