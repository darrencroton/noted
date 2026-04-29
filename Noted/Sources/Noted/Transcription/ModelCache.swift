import Foundation
import FluidAudio

enum ModelCacheStatus: Equatable {
    case cached
    case missing
    case builtIn

    var displayText: String {
        switch self {
        case .cached: return "Cached"
        case .missing: return "Not cached"
        case .builtIn: return "Built in"
        }
    }

    var systemImage: String {
        switch self {
        case .cached, .builtIn: return "checkmark.circle.fill"
        case .missing: return "arrow.down.circle"
        }
    }
}

enum ModelCache {
    static func status(for model: TranscriptionModel) -> ModelCacheStatus {
        switch model {
        case .parakeet:
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            return AsrModels.modelsExist(at: cacheDir, version: .v3) ? .cached : .missing
        case .whisperBase, .whisperLargeV3:
            guard let modelID = model.whisperModelID else { return .missing }
            return FileManager.default.fileExists(atPath: whisperModelURL(for: modelID).path) ? .cached : .missing
        case .appleSpeech:
            return .builtIn
        }
    }

    static func whisperDownloadBaseURL() -> URL {
        RuntimeFiles.supportDirectory
    }

    static func whisperModelURL(for modelID: String) -> URL {
        whisperRepositoryURL().appendingPathComponent(modelID, isDirectory: true)
    }

    private static func whisperRepositoryURL() -> URL {
        whisperDownloadBaseURL()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }
}
