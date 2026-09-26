import AppKit
import CoreAudio
import Foundation
import Observation

/// Optional, app-local audio side effects around a recording session.
/// All options are disabled by default; this controller does not start or keep
/// a microphone running.
@MainActor
@Observable
final class RecordingAudioOptionsController {
    private(set) var statusMessage = "Recording audio options are off."

    var pauseSupportedPlayersWhenRecording: Bool {
        didSet { defaults.set(pauseSupportedPlayersWhenRecording, forKey: Self.pausePlayersKey) }
    }

    var lowerOutputVolumeWhenRecording: Bool {
        didSet { defaults.set(lowerOutputVolumeWhenRecording, forKey: Self.lowerVolumeKey) }
    }

    /// Percentage of the current output level to reduce while recording (0–100).
    var outputVolumeReductionPercent: Double {
        didSet { defaults.set(outputVolumeReductionPercent, forKey: Self.volumeReductionKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRecording = false
    @ObservationIgnored private var pausedByController: Set<MediaPlayer> = []
    @ObservationIgnored private var savedOutputVolume: SavedOutputVolume?

    private static let pausePlayersKey = "EchoFlow.pausePlayersWhileRecording"
    private static let lowerVolumeKey = "EchoFlow.lowerOutputVolumeWhileRecording"
    private static let volumeReductionKey = "EchoFlow.outputVolumeReductionPercent"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pauseSupportedPlayersWhenRecording = defaults.bool(forKey: Self.pausePlayersKey)
        self.lowerOutputVolumeWhenRecording = defaults.bool(forKey: Self.lowerVolumeKey)
        self.outputVolumeReductionPercent = defaults.object(forKey: Self.volumeReductionKey) as? Double ?? 20
    }

    /// Call only after the recording engine has successfully started.
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pausedByController.removeAll()
        savedOutputVolume = nil

        var messages = [String]()
        if pauseSupportedPlayersWhenRecording {
            for player in MediaPlayer.allCases {
                switch pauseIfPlaying(player) {
                case .paused:
                    pausedByController.insert(player)
                    messages.append("Paused \(player.displayName).")
                case .notRunning:
                    messages.append("\(player.displayName) was not running.")
                case .notPlaying:
                    messages.append("\(player.displayName) was not playing.")
                case .failed(let reason):
                    messages.append("Could not control \(player.displayName): \(reason)")
                }
            }
        } else {
            messages.append("Media-player pausing is off.")
        }
        messages.append("Browser media players are not controlled.")

        if lowerOutputVolumeWhenRecording {
            switch lowerOutputVolume() {
            case .success(let description):
                messages.append(description)
            case .failure(let reason):
                messages.append("Output volume was not changed: \(reason)")
            }
        } else {
            messages.append("Output-volume reduction is off.")
        }

        messages.append("Instant-on microphone is unavailable; the microphone is not kept open between recordings.")
        statusMessage = messages.joined(separator: " ")
    }

    /// Call when the recording session ends, including cancellation/discard.
    func stopRecording() {
        guard isRecording else {
            statusMessage = "No recording audio options are active."
            return
        }
        isRecording = false

        var messages = [String]()
        for player in MediaPlayer.allCases where pausedByController.contains(player) {
            switch resumeIfStillPaused(player) {
            case .resumed:
                messages.append("Resumed \(player.displayName), which EchoFlow paused.")
            case .notRunning:
                messages.append("Did not resume \(player.displayName); it is no longer running.")
            case .notPaused:
                messages.append("Did not resume \(player.displayName); it is no longer paused.")
            case .failed(let reason):
                messages.append("Could not resume \(player.displayName): \(reason)")
            }
        }
        pausedByController.removeAll()

        if let savedOutputVolume {
            switch restoreOutputVolume(savedOutputVolume) {
            case .success:
                messages.append("Requested restoration of the exact saved output volume.")
            case .failure(let reason):
                messages.append("Could not restore the saved output volume: \(reason)")
            }
            self.savedOutputVolume = nil
        }

        statusMessage = messages.isEmpty
            ? "Recording audio options stopped; no changes needed restoration."
            : messages.joined(separator: " ")
    }

    private func pauseIfPlaying(_ player: MediaPlayer) -> PlayerPauseResult {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty == false else {
            return .notRunning
        }
        let source = """
        on run
            tell application id "\(player.bundleIdentifier)"
                if player state is playing then
                    pause
                    return "paused"
                else
                    return "not_playing"
                end if
            end tell
        end run
        """
        switch runAppleScript(source) {
        case .success(let result):
            switch result {
            case "paused": return .paused
            case "not_playing": return .notPlaying
            default: return .failed("the player returned an unrecognized playback state.")
            }
        case .failure(let reason):
            return .failed(reason)
        }
    }

    private func resumeIfStillPaused(_ player: MediaPlayer) -> PlayerResumeResult {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty == false else {
            return .notRunning
        }
        let source = """
        on run
            tell application id "\(player.bundleIdentifier)"
                if player state is paused then
                    play
                    return "resumed"
                else
                    return "not_paused"
                end if
            end tell
        end run
        """
        switch runAppleScript(source) {
        case .success(let result):
            switch result {
            case "resumed": return .resumed
            case "not_paused": return .notPaused
            default: return .failed("the player returned an unrecognized playback state.")
            }
        case .failure(let reason):
            return .failed(reason)
        }
    }

    private func runAppleScript(_ source: String) -> OperationResult<String> {
        guard let script = NSAppleScript(source: source) else {
            return .failure("AppleScript could not be created.")
        }
        var error: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        guard let result else {
            return .failure(error?.description ?? "Automation was unavailable or denied.")
        }
        return .success(result.stringValue ?? "")
    }

    private func lowerOutputVolume() -> OperationResult<String> {
        let reduction = min(max(outputVolumeReductionPercent.isFinite ? outputVolumeReductionPercent : 0, 0), 100)
        guard reduction > 0 else { return .success("Output-volume reduction is set to 0%.") }

        do {
            let saved = try currentOutputVolume()
            let reducedLevel = saved.previousLevel * Float32(1 - reduction / 100)
            var address = saved.address
            var canSet = DarwinBoolean(false)
            let settableStatus = AudioObjectIsPropertySettable(saved.deviceID, &address, &canSet)
            guard settableStatus == noErr, canSet.boolValue else {
                return .failure("the current output device has no writable main-volume control.")
            }
            var level = reducedLevel
            let status = AudioObjectSetPropertyData(
                saved.deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &level
            )
            guard status == noErr else {
                return .failure("Core Audio returned status \(status).")
            }
            savedOutputVolume = saved
            return .success(String(format: "Requested output-volume reduction by %.1f%%; the exact prior level is saved for restoration.", reduction))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func currentOutputVolume() throws -> SavedOutputVolume {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            systemObject,
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioOptionsError.defaultOutputUnavailable(deviceStatus)
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(0)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let volumeStatus = AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )
        guard volumeStatus == noErr else {
            throw AudioOptionsError.outputVolumeUnavailable(volumeStatus)
        }
        guard volume.isFinite, (0...1).contains(volume) else {
            throw AudioOptionsError.invalidOutputVolume
        }
        return SavedOutputVolume(deviceID: deviceID, address: volumeAddress, previousLevel: volume)
    }

    private func restoreOutputVolume(_ saved: SavedOutputVolume) -> OperationResult<Void> {
        var address = saved.address
        var canSet = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(saved.deviceID, &address, &canSet)
        guard settableStatus == noErr, canSet.boolValue else {
            return .failure("the original output device is unavailable or no longer writable.")
        }
        var level = saved.previousLevel
        let status = AudioObjectSetPropertyData(
            saved.deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &level
        )
        return status == noErr ? .success(()) : .failure("Core Audio returned status \(status).")
    }
}

private enum MediaPlayer: CaseIterable, Hashable {
    case music
    case spotify

    var bundleIdentifier: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

private struct SavedOutputVolume {
    let deviceID: AudioDeviceID
    let address: AudioObjectPropertyAddress
    let previousLevel: Float32
}

private enum PlayerPauseResult {
    case paused
    case notRunning
    case notPlaying
    case failed(String)
}

private enum PlayerResumeResult {
    case resumed
    case notRunning
    case notPaused
    case failed(String)
}

private enum OperationResult<Value> {
    case success(Value)
    case failure(String)
}

private enum AudioOptionsError: LocalizedError {
    case defaultOutputUnavailable(OSStatus)
    case outputVolumeUnavailable(OSStatus)
    case invalidOutputVolume

    var errorDescription: String? {
        switch self {
        case .defaultOutputUnavailable(let status):
            "the default output device is unavailable (Core Audio status \(status))."
        case .outputVolumeUnavailable(let status):
            "the current output device does not expose a readable main-volume control (Core Audio status \(status))."
        case .invalidOutputVolume:
            "Core Audio returned an invalid output-volume value."
        }
    }
}
