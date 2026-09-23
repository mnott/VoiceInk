import FluidAudio
import Foundation

/// Where FluidAudio's standard diarizer model pair (pyannote segmentation + WeSpeaker embedding -
/// see `MeetingSpeakerEmbedder`) is cached, and whether it is already downloaded. Meeting Capture
/// only ever reads this; the explicit "Download" action on the AI Models page
/// (`MeetingSpeakerEmbeddingModelManager`) is the only thing that triggers a download, matching
/// `MeetingDiarizationModels`' no-silent-download convention for the (separate) Nemotron 3
/// diarization model.
///
/// Only the embedding model does real work for speaker fingerprinting (see
/// `MeetingSpeakerEmbedder.embedding(for:)`, which passes an all-ones mask); the segmentation
/// model is downloaded alongside it only because `DiarizerManager.extractSpeakerEmbedding` reads
/// its output shape to size that mask - FluidAudio does not expose the embedding model on its own.
enum MeetingSpeakerEmbeddingModels {
    static var cacheDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer) }

    private static func isBundleComplete(_ modelFileName: String) -> Bool {
        FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(modelFileName).appendingPathComponent("coremldata.bin").path)
    }

    static var isDownloaded: Bool {
        isBundleComplete(ModelNames.Diarizer.segmentationFile) && isBundleComplete(ModelNames.Diarizer.embeddingFile)
    }
}
