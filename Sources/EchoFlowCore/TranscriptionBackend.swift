import Foundation

public enum TranscriptionBackend: Equatable, Sendable {
    case appleSpeech
    case parakeetV3
    case whisperLargeV3Turbo
    case unavailable(engineID: String)

    public static func resolve(
        engineID: String,
        catalog: ModelCatalog,
        installedDownloadIDs: Set<String>
    ) -> TranscriptionBackend {
        guard let engine = catalog.engine(id: engineID) else {
            return .unavailable(engineID: engineID)
        }
        guard engineID != ModelSelection.appleSpeechEngineID else {
            return .appleSpeech
        }
        guard let downloadID = engine.downloadId,
              installedDownloadIDs.contains(downloadID) else {
            return .unavailable(engineID: engineID)
        }

        switch engineID {
        case ModelSelection.parakeetEngineID:
            return .parakeetV3
        case "whisper-large-v3-turbo":
            return .whisperLargeV3Turbo
        default:
            return .unavailable(engineID: engineID)
        }
    }
}
