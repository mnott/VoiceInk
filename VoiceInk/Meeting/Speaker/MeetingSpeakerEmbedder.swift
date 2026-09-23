import FluidAudio
import Foundation
import os

/// Extracts a 256-dim WeSpeaker speaker embedding from a short (>= ~1.5s, ideally ~10s total),
/// single-voice audio clip, for the speaker library's fingerprint matching (see
/// `SpeakerMatching`). Lazily loads FluidAudio's standard diarizer model pair once per app run and
/// reuses it - `nil` if the models aren't downloaded yet or fail to load; never triggers a
/// download itself (see `MeetingSpeakerEmbeddingModels`), matching `MeetingDiarizer`'s convention
/// for the (separate) Nemotron 3 turn-taking diarizer.
actor MeetingSpeakerEmbedder {
    static let shared = MeetingSpeakerEmbedder()

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingSpeakerEmbedder")

    private var manager: DiarizerManager?
    private var loadFailed = false

    private init() {}

    func embedding(for samples: [Int16]) async -> [Float]? {
        guard let manager = await loadedManager() else { return nil }
        let floats = samples.map { Float($0) / 32768.0 }
        do {
            return try manager.extractSpeakerEmbedding(from: floats)
        } catch {
            Self.logger.error("Speaker embedding extraction failed: \(error, privacy: .public)")
            return nil
        }
    }

    private func loadedManager() async -> DiarizerManager? {
        if let manager { return manager }
        guard !loadFailed, MeetingSpeakerEmbeddingModels.isDownloaded else { return nil }
        do {
            // Both models are already downloaded (checked above) - this only loads them into
            // memory, the same "checks cache, never re-downloads what's present" trust already
            // extended to `Nemotron3Diarizer.makeIfAvailable` for the sibling turn-taking model.
            let models = try await DiarizerModels.downloadIfNeeded()
            let newManager = DiarizerManager()
            newManager.initialize(models: models)
            manager = newManager
            return newManager
        } catch {
            Self.logger.error("Failed to load speaker embedding models: \(error, privacy: .public)")
            loadFailed = true
            return nil
        }
    }
}
