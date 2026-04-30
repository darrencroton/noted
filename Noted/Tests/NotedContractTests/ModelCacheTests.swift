@testable import Noted
import XCTest

final class ModelCacheTests: XCTestCase {
    func testRuntimeModelCachesLiveUnderNotedApplicationSupport() {
        let modelsRoot = RuntimeFiles.supportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .standardizedFileURL

        XCTAssertEqual(ModelCache.modelsDirectory.standardizedFileURL, modelsRoot)
        XCTAssertTrue(ModelCache.parakeetModelURL.standardizedFileURL.path.hasPrefix(modelsRoot.path))
        XCTAssertTrue(ModelCache.diarizationModelURL.standardizedFileURL.path.hasPrefix(modelsRoot.path))

        XCTAssertFalse(ModelCache.parakeetModelURL.path.contains("/Application Support/FluidAudio/"))
        XCTAssertFalse(ModelCache.diarizationModelURL.path.contains("/Application Support/FluidAudio/"))
    }

    func testWhisperCacheStatusPathsRemainUnderNotedModelRoot() throws {
        let baseID = try XCTUnwrap(TranscriptionModel.whisperBase.whisperModelID)
        let largeID = try XCTUnwrap(TranscriptionModel.whisperLargeV3.whisperModelID)
        let modelsRoot = ModelCache.modelsDirectory.standardizedFileURL.path

        XCTAssertTrue(ModelCache.whisperModelURL(for: baseID).standardizedFileURL.path.hasPrefix(modelsRoot))
        XCTAssertTrue(ModelCache.whisperModelURL(for: largeID).standardizedFileURL.path.hasPrefix(modelsRoot))
    }

    func testDefaultDiarizationRunnerUsesNotedModelCache() {
        let runner = FluidAudioDiarizationRunner()

        XCTAssertEqual(
            runner.modelDirectory.standardizedFileURL,
            ModelCache.fluidAudioModelsDirectory.standardizedFileURL
        )
    }
}
