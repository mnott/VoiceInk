import Foundation

/// Turns a `MeetingDiarizer`'s absolute-sample speaker segments into one chunk/super-block's
/// local-sample regions, tracking a watermark so a segment the diarizer only finishes computing
/// after its owning chunk has already been cut - normal, since streaming/offline profiles commit
/// with several seconds of latency - is attributed exactly once instead of twice or never: it
/// simply shows up (still labelled by the same diarized speaker) at whichever later chunk's
/// window it lands in once committed. Model-free and pure so it is unit-testable without a
/// downloaded model or live audio (see `MeetingDiarizationTests`).
enum MeetingDiarizationAttributor {
    struct Attribution: Equatable {
        /// Diarized speaker segments landing in this chunk, in chunk-local sample coordinates.
        let regions: [(speaker: Int, start: Int, end: Int)]
        /// Local sample offset the diarizer had committed through as of this chunk's cut - the
        /// remaining tail `[coveredThroughSample, chunkLength)` is this chunk's own audio the
        /// diarizer hasn't processed yet, and needs a VAD fallback (see `MeetingTurnTranscriber`).
        let coveredThroughSample: Int

        static func == (lhs: Attribution, rhs: Attribution) -> Bool {
            lhs.coveredThroughSample == rhs.coveredThroughSample
                && lhs.regions.elementsEqual(rhs.regions) { $0.speaker == $1.speaker && $0.start == $1.start && $0.end == $1.end }
        }
    }

    /// - Parameters:
    ///   - segments: Every segment the diarizer has committed so far, in absolute (session-global)
    ///     sample coordinates - recomputed from its full probability history each call.
    ///   - reportedThroughSample: The watermark returned by the previous call for this session (0
    ///     for the first chunk/super-block).
    ///   - committedThroughSample: How far (absolute samples) the diarizer has computed
    ///     probabilities for, as of this cut.
    ///   - chunkStartGlobal / chunkEndGlobal: This chunk's absolute sample window; consecutive
    ///     calls for the same session must supply contiguous, non-overlapping windows in order.
    static func attribute(
        segments: [(speaker: Int, start: Int, end: Int)],
        reportedThroughSample: Int,
        committedThroughSample: Int,
        chunkStartGlobal: Int, chunkEndGlobal: Int
    ) -> (attribution: Attribution, nextReportedThroughSample: Int) {
        var regions: [(speaker: Int, start: Int, end: Int)] = []
        for segment in segments {
            let start = max(segment.start, reportedThroughSample, chunkStartGlobal)
            let end = min(segment.end, chunkEndGlobal)
            guard end > start else { continue }
            regions.append((segment.speaker, start - chunkStartGlobal, end - chunkStartGlobal))
        }

        let coveredThroughGlobal = max(chunkStartGlobal, min(committedThroughSample, chunkEndGlobal))
        let attribution = Attribution(regions: regions, coveredThroughSample: coveredThroughGlobal - chunkStartGlobal)
        return (attribution, chunkEndGlobal)
    }
}
