import Foundation
import FluidAudio
import WhisperKit

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
    static var modelsDirectory: URL {
        RuntimeFiles.supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var fluidAudioModelsDirectory: URL {
        modelsDirectory.appendingPathComponent("fluidaudio", isDirectory: true)
    }

    static var parakeetModelURL: URL {
        fluidAudioModelsDirectory.appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)
    }

    static var diarizationModelURL: URL {
        fluidAudioModelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    static func status(for model: TranscriptionModel) -> ModelCacheStatus {
        switch model {
        case .parakeet:
            return AsrModels.modelsExist(at: parakeetModelURL, version: .v3) ? .cached : .missing
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

    static func prefetchStartupModels() async -> [String] {
        migrateLegacyFluidAudioCaches()

        var failures: [String] = []
        for model in [TranscriptionModel.parakeet, .whisperBase, .whisperLargeV3] {
            do {
                try await ensureModelCached(model)
            } catch {
                failures.append("\(model.displayName): \(error.localizedDescription)")
            }
        }

        do {
            try await ensureDiarizationModelsCached()
        } catch {
            failures.append("FluidAudio diarization: \(error.localizedDescription)")
        }

        return failures
    }

    static func ensureModelCached(_ model: TranscriptionModel) async throws {
        switch model {
        case .parakeet:
            try await AsrModels.download(to: parakeetModelURL, version: .v3)
        case .whisperBase, .whisperLargeV3:
            guard let modelID = model.whisperModelID else { return }
            _ = try await WhisperKit(model: modelID, downloadBase: whisperDownloadBaseURL())
            if let variant = model.whisperVariant {
                _ = try await ModelUtilities.loadTokenizer(for: variant, tokenizerFolder: whisperDownloadBaseURL())
            }
        case .appleSpeech:
            return
        }
    }

    static func ensureDiarizationModelsCached() async throws {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels(directory: fluidAudioModelsDirectory)
    }

    private static func migrateLegacyFluidAudioCaches() {
        migrateDirectory(from: AsrModels.defaultCacheDirectory(for: .v3), to: parakeetModelURL)

        let legacyDiarizationURL = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        migrateDirectory(from: legacyDiarizationURL, to: diarizationModelURL)
    }

    private static func migrateDirectory(from sourceURL: URL, to destinationURL: URL) {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path else { return }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try? fileManager.copyItem(at: source, to: destination)
        }
    }
}
