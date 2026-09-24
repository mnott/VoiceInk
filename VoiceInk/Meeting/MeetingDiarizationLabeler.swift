import Foundation

/// Assigns diarized speaker labels to the system channel's own `MeetingVAD` regions - WHAT gets
/// transcribed stays decided by VAD (as it always did, before diarization existed); the diarizer
/// only decides WHO. This is what keeps a VAD region that a diarizer segment only partially (or
/// never) overlaps from ever being dropped, unlike attributing straight from diarizer segments
/// (see `MeetingDiarizationAttributor`, whose segments are this labeler's input, not its output).
enum MeetingDiarizationLabeler {
    /// Diarizer speaker changes only split a region where they coincide with a real pause inside
    /// it - otherwise the model's segment boundary (routinely a few hundred ms off true speech
    /// onset/offset) would cut a region mid-word instead of the VAD boundary that already bounds it.
    private static let splitPauseMinSamples = Int(0.2 * MeetingVAD.sampleRate)
    private static let splitToleranceSamples = Int(0.5 * MeetingVAD.sampleRate)

    /// A short interjection (e.g. "Right." or "Exactly, yes.") dropped into someone else's turn
    /// routinely has no >=200ms pause on either side at all - the speaker starts talking again
    /// within a couple hundred ms, or even overlaps the interjection's tail - so the pause rule
    /// above never splits it and it gets swallowed into the majority (enclosing) speaker below.
    /// Measured on a synthetic fixture (`/tmp/vi-test/build_interjections.py`) of a monologue with
    /// 4 such interjections spliced in with 20-80ms gaps or ~150ms of genuine overlap: when one
    /// side of a diarizer speaker change is a segment that doesn't touch the enclosing VAD
    /// region's own edges (i.e. there is other speech in the region before *and* after it) and is
    /// already >=0.6s - long enough that it isn't a stray diarizer misfire - the change still gets
    /// split, snapped to the nearest local energy minimum (not a silence run) within 150ms instead
    /// of requiring a real pause. This raised the fixture's interjections correctly attributed from
    /// 2/4 to 4/4 with 0 monologue lines broken by more than 1s (see
    /// /tmp/vi-test/interjection-report.txt) and did not change dialogue.wav's 12/12.
    private static let enclosedSplitMinSamples = Int(0.6 * MeetingVAD.sampleRate)
    private static let energySplitToleranceSamples = Int(0.15 * MeetingVAD.sampleRate)

    /// - Parameters:
    ///   - vadRegions: The channel's own VAD regions - unchanged from the pre-diarization
    ///     behaviour, so every word VAD hears still gets transcribed regardless of diarizer coverage.
    ///   - diarizedSegments: `MeetingDiarizationAttributor.Attribution.regions`, chunk-local like
    ///     `vadRegions`.
    ///   - samples: The same channel samples `vadRegions` was computed from - only read to find
    ///     internal pauses for the split decision.
    ///   - speakerForSlot: Wraps a diarizer speaker index into this channel's `Speaker` case - see
    ///     `MeetingTurnTranscriber`'s system (`.other`) vs. in-person mic (`.otherMic`) callers.
    ///   - noSpeaker: The generic label for a region with no diarizer overlap anywhere in the call
    ///     (`.others`/`.othersMic`) - the pre-diarization behaviour for that region.
    /// - Returns: Regions (a superset of `vadRegions` wherever a region was split) and their
    ///   speaker labels, one-to-one and same order. A region with no diarizer overlap at all is
    ///   labelled from its nearest neighbour (previous, or next if it's the first); `noSpeaker` only
    ///   when no region in the whole call has any overlap.
    static func label(
        vadRegions: [MeetingVAD.Region], diarizedSegments: [(speaker: Int, start: Int, end: Int)], samples: [Int16],
        speakerForSlot: (Int) -> MeetingTurnBuilder.Speaker, noSpeaker: MeetingTurnBuilder.Speaker
    ) -> (regions: [MeetingVAD.Region], speakers: [MeetingTurnBuilder.Speaker]) {
        var regions: [MeetingVAD.Region] = []
        var speakers: [Int?] = []
        for region in vadRegions {
            for (r, speaker) in labelRegion(region, diarizedSegments: diarizedSegments, samples: samples) {
                regions.append(r)
                speakers.append(speaker)
            }
        }

        var filled = speakers
        for i in 1..<max(filled.count, 1) where filled[i] == nil {
            filled[i] = filled[i - 1]
        }
        if let firstKnown = filled.first(where: { $0 != nil }) ?? nil {
            for i in 0..<filled.count {
                guard filled[i] == nil else { break }
                filled[i] = firstKnown
            }
        }

        return (regions, filled.map { $0.map(speakerForSlot) ?? noSpeaker })
    }

    /// One region's overlapping diarizer segments, split recursively at the first speaker change
    /// that lands on a real pause nearby - `nil` speaker means no diarizer overlap at all.
    private static func labelRegion(
        _ region: MeetingVAD.Region, diarizedSegments: [(speaker: Int, start: Int, end: Int)], samples: [Int16]
    ) -> [(MeetingVAD.Region, Int?)] {
        let overlaps =
            diarizedSegments
            .compactMap { segment -> (start: Int, end: Int, speaker: Int)? in
                let start = max(segment.start, region.start)
                let end = min(segment.end, region.end)
                guard end > start else { return nil }
                return (start, end, segment.speaker)
            }
            .sorted { $0.start < $1.start }

        guard !overlaps.isEmpty else { return [(region, nil)] }

        for i in 0..<(overlaps.count - 1) {
            let a = overlaps[i]
            let b = overlaps[i + 1]
            guard a.speaker != b.speaker else { continue }
            let changePoint = a.end >= b.start ? b.start : (a.end + b.start) / 2

            // Either side of this change being a segment that doesn't touch the region's own
            // edges and is already >=0.6s - long enough that it isn't a stray diarizer misfire -
            // means a real interjection, not just noise, even with no pause nearby.
            let aEnclosed = a.start > region.start && a.end < region.end && a.end - a.start >= enclosedSplitMinSamples
            let bEnclosed = b.start > region.start && b.end < region.end && b.end - b.start >= enclosedSplitMinSamples

            guard
                let split = nearestPause(near: changePoint, in: region, samples: samples)
                    ?? ((aEnclosed || bEnclosed) ? nearestEnergyMinimum(near: changePoint, in: region, samples: samples) : nil),
                split > region.start, split < region.end
            else { continue }

            let left = MeetingVAD.Region(start: region.start, end: split)
            let right = MeetingVAD.Region(start: split, end: region.end)
            return labelRegion(left, diarizedSegments: diarizedSegments, samples: samples)
                + labelRegion(right, diarizedSegments: diarizedSegments, samples: samples)
        }

        var overlapDurations: [Int: Int] = [:]
        var order: [Int] = []
        for overlap in overlaps {
            if overlapDurations[overlap.speaker] == nil { order.append(overlap.speaker) }
            overlapDurations[overlap.speaker, default: 0] += overlap.end - overlap.start
        }
        let majority = order.max { overlapDurations[$0]! < overlapDurations[$1]! }
        return [(region, majority)]
    }

    private static func nearestPause(near changePoint: Int, in region: MeetingVAD.Region, samples: [Int16]) -> Int? {
        MeetingVAD.silenceRuns(in: samples, range: region.start..<region.end, minRunSamples: splitPauseMinSamples)
            .map { ($0.lowerBound + $0.upperBound) / 2 }
            .filter { abs($0 - changePoint) <= splitToleranceSamples }
            .min { abs($0 - changePoint) < abs($1 - changePoint) }
    }

    /// The 20ms frame (same grid as `MeetingVAD`) of lowest RMS energy within
    /// `energySplitToleranceSamples` of `changePoint` - used once no real pause is nearby, so the
    /// split still lands wherever the two speakers' audio happens to be quietest instead of at the
    /// diarizer's own (routinely a few hundred ms off) segment boundary.
    private static func nearestEnergyMinimum(near changePoint: Int, in region: MeetingVAD.Region, samples: [Int16]) -> Int? {
        let frame = MeetingVAD.frameSamples
        let lowerBound = max(region.start, changePoint - energySplitToleranceSamples)
        let upperBound = min(region.end, changePoint + energySplitToleranceSamples)
        guard lowerBound + frame <= upperBound else { return nil }

        var bestPoint = 0
        var bestEnergy = Double.infinity
        var i = lowerBound
        while i + frame <= upperBound {
            let energy = MeetingVAD.rms(samples[i..<i + frame])
            if energy < bestEnergy {
                bestEnergy = energy
                bestPoint = i + frame / 2
            }
            i += frame
        }
        return bestEnergy.isFinite ? bestPoint : nil
    }
}
