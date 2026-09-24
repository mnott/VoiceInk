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
    private var finished = false
    /// Real (non-padding) samples handed to `append` - `finish()` needs this to trim off the
    /// silence padding it feeds the model to flush the tail (see `finish()`'s doc comment).
    private var appendedSampleCount = 0

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
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config, computeUnits: MeetingDiarizationModels.computeUnits(for: config))
            return MeetingDiarizer(models: models, config: config)
        } catch {
            staticLogger.error("Failed to load Nemotron 3 diarization model: \(error, privacy: .public)")
            return nil
        }
    }

    /// Feed 16 kHz mono samples as they arrive (or, for the whole-meeting note, as each
    /// super-block is read). Safe to call repeatedly; a no-op once `failed` or `finished` - the
    /// latter matters because a caller can race `finish()` (e.g. a manual chunk send delayed
    /// behind `MeetingAudioCapture.cutForManualSend`'s send delay, landing on `tapQueue` after
    /// `stop()`'s `finish()` already ran): `Nemotron3Diarizer.appendAudio` traps if called after
    /// `finishStream()`, so this guard - not caller ordering - is what has to make that safe.
    func append(_ samples: [Int16]) {
        guard Self.shouldAppend(failed: failed, finished: finished, samplesEmpty: samples.isEmpty) else { return }
        appendedSampleCount += samples.count
        let floats = samples.map { Float($0) / 32768.0 }
        diarizer.appendAudio(floats)
        do {
            for chunk in try diarizer.processBufferedAudio() {
                probabilities.append(contentsOf: chunk.probabilities)
            }
        } catch {
            // Whatever landed in `probabilities` from earlier, successful calls stays - only
            // this session's further processing stops (see `attribute()`, which keeps working
            // on it instead of failing outright).
            logger.error("Meeting diarizer streaming step failed, disabling for this session: \(error, privacy: .public)")
            failed = true
        }
    }

    /// Flushes the trailing partial chunk. Call once, after the last `append`, before the final
    /// `attribute(chunkStartGlobal:chunkEndGlobal:)` call for the session. Idempotent - a second
    /// call (e.g. `stop()` racing another path that also finishes the same session) is a no-op.
    ///
    /// Deliberately never calls `Nemotron3Diarizer.finishStream()`: its zero-padded-to-end final
    /// chunk is shorter than every other chunk this session has run, and the model's preallocated,
    /// fixed-shape output backings (`Nemotron3Models`) don't match that shape - CoreML throws
    /// "Output backing ... not compatible" instead of returning a result. Padding the buffered
    /// tail with silence out to a full chunk first and flushing it through the ordinary
    /// `processBufferedAudio()` path keeps every call the same shape as a normal mid-stream chunk;
    /// the padding-covered frames beyond the real audio are then trimmed back off.
    func finish() {
        guard Self.shouldFinish(failed: failed, finished: finished) else { return }
        finished = true
        do {
            // More than enough silence to complete the one partial chunk `processBufferedAudio`
            // could have pending (at most `latencySeconds` of audio short of a full chunk, since
            // `append` already drains every completable chunk eagerly); the extra frame is slop
            // for the mel window's own rounding.
            let paddingSamples =
                Int(diarizer.config.latencySeconds * Double(Self.sampleRate)) + Self.outputFrameSamples
            diarizer.appendAudio([Float](repeating: 0, count: paddingSamples))
            for chunk in try diarizer.processBufferedAudio() {
                probabilities.append(contentsOf: chunk.probabilities)
            }
            let realFrameCount = appendedSampleCount / Self.outputFrameSamples
            let realProbabilityCount = realFrameCount * 8
            if probabilities.count > realProbabilityCount {
                probabilities.removeLast(probabilities.count - realProbabilityCount)
            }
        } catch {
            logger.error("Meeting diarizer finish failed: \(error, privacy: .public)")
            failed = true
        }
    }

    /// Pure decision behind the `append`/`finish` guards above, factored out so the
    /// append-after-finish fix is unit-testable without loading a real model.
    static func shouldAppend(failed: Bool, finished: Bool, samplesEmpty: Bool) -> Bool {
        !failed && !finished && !samplesEmpty
    }

    static func shouldFinish(failed: Bool, finished: Bool) -> Bool {
        !failed && !finished
    }

    /// How far (absolute samples) this session has committed diarized probabilities for - a
    /// read-only peek `MeetingAudioCapture` polls (without consuming the watermark the way
    /// `attribute` does) to wait for a chunk's tail to actually commit before falling back to
    /// treating it as uncovered.
    var committedThroughSample: Int { (probabilities.count / 8) * Self.outputFrameSamples }

    /// Resets the attribution watermark to the start of the session - for reusing a session
    /// that already served live per-chunk delivery (whose own `attribute()` calls advanced the
    /// watermark through the whole recording) for a second, independent full-timeline pass, e.g.
    /// `MeetingRecordingTranscriber` re-walking the same session's recording for the meeting note.
    func resetAttributionWatermark() { reportedThroughSample = 0 }

    /// Attributes one chunk/super-block's absolute-sample window to diarized speakers (see
    /// `MeetingDiarizationAttributor`). Call exactly once per chunk/super-block, in session order.
    /// Keeps working off whatever probabilities were computed before a failure rather than
    /// returning nothing - a chunk with no attributed speech at all still falls back to plain VAD
    /// (see `MeetingDiarizationAttributor`'s "continuation" doc comment), it just never recovers
    /// speaker segments a failed session stopped computing.
    func attribute(chunkStartGlobal: Int, chunkEndGlobal: Int) -> MeetingDiarizationAttributor.Attribution {
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
