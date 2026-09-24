import CoreML
import FluidAudio
import Foundation

/// Where the Nemotron 3 diarization presets Meeting Capture uses (`.offline` for the whole-meeting
/// note, `.fast32` for live chunks - see `MeetingDiarizer`) are cached, and whether both are
/// already downloaded. Meeting Capture only ever reads this - the explicit "Download" action on
/// the AI Models page (`MeetingDiarizationModelManager`) is the only thing that triggers a
/// download, per the no-silent-download requirement.
enum MeetingDiarizationModels {
    static let offlineConfig = Nemotron3Config.offline
    static let streamingConfig = Nemotron3Config.fast32

    /// `offline`'s compiled model is GPU-only (FluidAudio's own model card notes an ANE compiler
    /// limit for it - see `Documentation/Diarization/Nemotron3.md`): loading it with the default
    /// `.all` compute units routes it to ANE anyway, and CoreML throws "Output backing ... not
    /// compatible with the model's output feature description" instead of falling back to GPU.
    /// `streamingConfig` (`fast32`) has no such restriction and keeps the ANE-eligible default.
    static func computeUnits(for config: Nemotron3Config) -> MLComputeUnits {
        config.modelFileName == offlineConfig.modelFileName ? .cpuAndGPU : .all
    }

    static var cacheDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return
            base
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }

    static func isBundleComplete(_ config: Nemotron3Config) -> Bool {
        let bundle =
            cacheDirectory
            .appendingPathComponent(config.hubSubdirectory, isDirectory: true)
            .appendingPathComponent(config.modelFileName, isDirectory: true)
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path)
    }

    /// Both presets plus the shared silence-embedding asset are present - i.e. `Nemotron3Models
    /// .loadFromHuggingFace` will not touch the network for either config.
    static var isDownloaded: Bool {
        isBundleComplete(offlineConfig) && isBundleComplete(streamingConfig)
            && FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile).path)
    }
}
