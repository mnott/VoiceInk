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
        /// A chunk whose tail the diarizer hadn't committed by cut time (see
        /// `coveredThroughSample`'s doc comment) has its last region's `end` extended through the
        /// chunk boundary instead of leaving a gap - a continuation of that same speaker, not a
        /// new, generically-labelled turn (see `attribute`'s doc comment).
        let regions: [(speaker: Int, start: Int, end: Int)]
        /// Local sample offset the diarizer had committed through as of this chunk's cut -
        /// diagnostic only, the remaining tail `[coveredThroughSample, chunkLength)` is this
        /// chunk's own audio the diarizer hasn't processed yet. Always equal to the chunk length
        /// (fully covered) whenever `regions` is non-empty - see `attribute`'s doc comment.
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
    ///
    /// A chunk's tail the diarizer hasn't committed by cut time (`MeetingAudioCapture` waits a
    /// bounded amount of time for this before cutting - see its `diarizationCommitWaitSeconds` -
    /// but streaming/offline latency, or a diarizer failure mid-session, can still leave a
    /// shortfall) is handled two ways: if this chunk has at least one attributed remote-speaker
    /// region, the last one's `end` is extended through the chunk boundary - a continuation of
    /// that speaker, since real speaker turns run several seconds while the uncommitted tail is
    /// normally at most a few - rather than the caller splitting it into its own generic "Others"
    /// turn. Only a chunk with no attributed region at all reports the real shortfall via
    /// `coveredThroughSample` - diagnostic only: what actually gets transcribed is always decided
    /// by the caller's own VAD regions (see `MeetingDiarizationLabeler`), regardless of how much of
    /// a chunk diarization has reached.
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

        let chunkLength = chunkEndGlobal - chunkStartGlobal
        let coveredThroughGlobal = max(chunkStartGlobal, min(committedThroughSample, chunkEndGlobal))
        var coveredThroughSample = coveredThroughGlobal - chunkStartGlobal

        if coveredThroughSample < chunkLength, !regions.isEmpty {
            regions[regions.count - 1].end = chunkLength
            coveredThroughSample = chunkLength
        }

        let attribution = Attribution(regions: regions, coveredThroughSample: coveredThroughSample)
        return (attribution, chunkEndGlobal)
    }
}
