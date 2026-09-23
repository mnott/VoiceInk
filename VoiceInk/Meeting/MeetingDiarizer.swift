import FluidAudio
import Foundation
import os

/// One continuous Nemotron 3 diarization session over a meeting's system-audio channel: speaker
/// identity stays stable across incremental `append` calls (the diarizer's speaker cache/FIFO
/// state is never reset mid-session), unlike running a fresh diarizer per chunk. Shared by the
/// live per-chunk pipeline (`MeetingAudioCapture`, `.fast32` streaming profile, fed per drain
/// tick) and the whole-meeting note (`MeetingRecordingTranscriber`, `.offline` profile, fed per
/// memory-bounded super-block read) - both just need "continuous, incremental append + segment
/// retrieval", differing only in which `Nemotron3Config` they pass to `makeIfAvailable`.
///
/// Not thread-safe (matches `Nemotron3Diarizer` itself) - own one instance per session from a
/// single queue/task, same as its callers already do for VAD state.
final class MeetingDiarizer: @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer
    private var probabilities: [Float] = []
    private var reportedThroughSample = 0
    private(set) var failed = false

    private static let sampleRate: Float = 16000
    private static let outputFrameSamples = 160  // 10 ms at 16 kHz

    private static let staticLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingDiarizer")
    private let logger = MeetingDiarizer.staticLogger

    private init(models: Nemotron3Models, config: Nemotron3Config) {
        diarizer = Nemotron3Diarizer(config: config, models: models)
    }

    /// `nil` if the model isn't downloaded (see `MeetingDiarizationModels.isDownloaded`) or fails
    /// to load - callers fall back to the pre-diarization single-"Others" behaviour in either case,
    /// never triggering a download themselves.
    static func makeIfAvailable(config: Nemotron3Config) async -> MeetingDiarizer? {
        guard MeetingDiarizationModels.isDownloaded else { return nil }
        do {
            let models = try await Nemotron3Models.loadFromHuggingFace(config: config)
            return MeetingDiarizer(models: models, config: config)
        } catch {
            staticLogger.error("Failed to load Nemotron 3 diarization model: \(error, privacy: .public)")
            return nil
        }
    }

    /// Feed 16 kHz mono samples as they arrive (or, for the whole-meeting note, as each
    /// super-block is read). Safe to call repeatedly; a no-op once `failed`.
    func append(_ samples: [Int16]) {
        guard !failed, !samples.isEmpty else { return }
        let floats = samples.map { Float($0) / 32768.0 }
        diarizer.appendAudio(floats)
        do {
            for chunk in try diarizer.processBufferedAudio() {
                probabilities.append(contentsOf: chunk.probabilities)
            }
        } catch {
            logger.error("Meeting diarizer streaming step failed, disabling for this session: \(error, privacy: .public)")
            failed = true
        }
    }

    /// Flushes the trailing partial chunk. Call once, after the last `append`, before the final
    /// `attribute(chunkStartGlobal:chunkEndGlobal:)` call for the session.
    func finish() {
        guard !failed else { return }
        do {
            for chunk in try diarizer.finishStream() {
                probabilities.append(contentsOf: chunk.probabilities)
            }
        } catch {
            logger.error("Meeting diarizer finish failed: \(error, privacy: .public)")
            failed = true
        }
    }

    /// Attributes one chunk/super-block's absolute-sample window to diarized speakers (see
    /// `MeetingDiarizationAttributor`). Call exactly once per chunk/super-block, in session order;
    /// `nil` once the session has failed - callers should fall back to plain VAD from then on.
    func attribute(chunkStartGlobal: Int, chunkEndGlobal: Int) -> MeetingDiarizationAttributor.Attribution? {
        guard !failed else { return nil }
        let frameCount = probabilities.count / 8
        let segments = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount).map {
            (
                speaker: $0.speakerIndex,
                start: Int($0.startSeconds * Self.sampleRate),
                end: Int($0.endSeconds * Self.sampleRate)
            )
        }
        let committedThroughSample = frameCount * Self.outputFrameSamples
        let (attribution, next) = MeetingDiarizationAttributor.attribute(
            segments: segments, reportedThroughSample: reportedThroughSample,
            committedThroughSample: committedThroughSample,
            chunkStartGlobal: chunkStartGlobal, chunkEndGlobal: chunkEndGlobal)
        reportedThroughSample = next
        return attribution
    }
}
