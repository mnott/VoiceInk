import Testing
@testable import VoiceInk

// MARK: - Mapping diarized speaker segments to labelled "Speaker N" turns

struct MeetingTurnBuilderDiarizedSpeakerTests {
    private typealias Region = MeetingVAD.Region
    private typealias Turn = MeetingTurnBuilder.Turn
    private typealias Speaker = MeetingTurnBuilder.Speaker

    private func loud(_ count: Int) -> [Int16] {
        [Int16](repeating: 5000, count: count)
    }

    @Test func distinctDiarizedSpeakersProduceDistinctOrderedTurns() {
        // Two remote speakers taking turns, arrival-ordered 0 then 1 (mirrors Nemotron3's own
        // arrival ordering), with no mic activity at all.
        let turns = MeetingTurnBuilder.build(
            meRegions: [], othersRegions: [Region(start: 0, end: 1000), Region(start: 2000, end: 3000)],
            meSamples: [], othersSamples: loud(3000),
            othersSpeakers: [.other(0), .other(1)]
        )
        #expect(
            turns == [
                Turn(speaker: .other(0), start: 0, end: 1000),
                Turn(speaker: .other(1), start: 2000, end: 3000),
            ])
    }

    @Test func adjacentTurnsFromDifferentDiarizedSpeakersAreNotMergedIntoOneParagraph() {
        // Same boundary case `consecutiveSameSpeakerTurnsWithASmallGapAreMerged` covers for a
        // single speaker - back-to-back turns from two DIFFERENT diarized speakers, close enough
        // that same-speaker turns would merge, must stay separate paragraphs.
        let turns = MeetingTurnBuilder.build(
            meRegions: [], othersRegions: [Region(start: 0, end: 1000), Region(start: 1500, end: 2500)],
            meSamples: [], othersSamples: loud(2500),
            othersSpeakers: [.other(0), .other(1)]
        )
        #expect(
            turns == [
                Turn(speaker: .other(0), start: 0, end: 1000),
                Turn(speaker: .other(1), start: 1500, end: 2500),
            ])
    }

    @Test func meInterjectingADiarizedSpeakerKeepsThatSpeakersLabelOnBothHalves() {
        // Same split-at-internal-pause case `MeetingTurnBuilderTests` covers for the generic
        // "Others" - the host's diarized speaker label must survive the split unchanged.
        let othersSamples = loud(13440) + [Int16](repeating: 0, count: 3840) + loud(32000 - 17280)
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 15000, end: 16000)], othersRegions: [Region(start: 0, end: 32000)],
            meSamples: loud(16000), othersSamples: othersSamples,
            othersSpeakers: [.other(2)]
        )
        #expect(
            turns == [
                Turn(speaker: .other(2), start: 0, end: 15360),
                Turn(speaker: .me, start: 15000, end: 16000),
                Turn(speaker: .other(2), start: 15360, end: 32000),
            ])
    }

    @Test func missingOthersSpeakersArrayFallsBackToTheGenericOthersLabel() {
        // Fewer speaker labels than regions (or the parameter omitted entirely) is the
        // pre-diarization / diarization-unavailable path - never a crash or a bogus index.
        let turns = MeetingTurnBuilder.build(
            meRegions: [], othersRegions: [Region(start: 0, end: 1000)], meSamples: [], othersSamples: loud(1000)
        )
        #expect(turns == [Turn(speaker: .others, start: 0, end: 1000)])
    }

    @Test func rendererLabelsDiarizedSpeakersWithEphemeralSpkIds() {
        typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn
        let rendered = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .other(0), text: "hello"),
            TranscribedTurn(speaker: .me, text: "hi"),
            TranscribedTurn(speaker: .other(1), text: "hey there"),
            TranscribedTurn(speaker: .others, text: "unlabelled fallback"),
        ])
        #expect(
            rendered
                == "[spk-0000:] hello\n\n[Me:] hi\n\n[spk-0001:] hey there\n\n[Others:] unlabelled fallback")
    }
}

// MARK: - Speaker-label consistency across chunks

struct MeetingDiarizationAttributorTests {
    /// Same diarized speaker index, reported across two sequential chunk windows fed from the
    /// same (continuous, never-reset) diarizer session, must land in each chunk's own window
    /// labelled with that same index - the guarantee `MeetingTurnTranscriptRenderer` then turns
    /// into "Speaker 1 stays Speaker 1" across chunks.
    @Test func sameSpeakerIndexIsReportedConsistentlyAcrossSequentialChunks() {
        // Session-global: speaker 0 talks [0, 8000); speaker 1 talks [9000, 17000), straddling the
        // chunk 1/chunk 2 boundary at 10000 - both already committed by the time chunk 1 is cut
        // (no latency shortfall), same as a real continuous, never-reset diarizer session would
        // report once caught up.
        let allSegments: [(speaker: Int, start: Int, end: Int)] = [
            (0, 0, 8000),
            (1, 9000, 17000),
        ]

        let (chunk1, watermark1) = MeetingDiarizationAttributor.attribute(
            segments: allSegments, reportedThroughSample: 0, committedThroughSample: 17000,
            chunkStartGlobal: 0, chunkEndGlobal: 10000)
        #expect(chunk1.regions.map(\.speaker) == [0, 1])
        #expect(chunk1.regions[0].start == 0 && chunk1.regions[0].end == 8000)
        // Speaker 1's turn starts at 9000, inside chunk 1's [0, 10000) window - clipped to the
        // window here; the rest is picked up by chunk 2 below, same speaker index either side.
        #expect(chunk1.regions[1].start == 9000 && chunk1.regions[1].end == 10000)
        #expect(chunk1.coveredThroughSample == 10000)

        let (chunk2, _) = MeetingDiarizationAttributor.attribute(
            segments: allSegments, reportedThroughSample: watermark1, committedThroughSample: 17000,
            chunkStartGlobal: 10000, chunkEndGlobal: 20000)
        // Same underlying speaker index (1) as its first half in chunk 1 - never remapped to a
        // different index just because it's a later chunk; this is what keeps "Speaker 2" (index 1)
        // the same person across chunks.
        #expect(chunk2.regions.map(\.speaker) == [1])
        #expect(chunk2.regions[0].start == 0 && chunk2.regions[0].end == 7000)  // 10000..17000, chunk-local
    }

    @Test func aSegmentNotYetCommittedByCutTimeIsDeferredToTheNextChunkNotDropped() {
        // The diarizer has only committed through 6000 by the time chunk 1 [0, 10000) is cut
        // (streaming latency) - chunk 1 must report that shortfall via `coveredThroughSample` so
        // the caller can VAD-fallback the rest, and chunk 2 must still see the segment once it is
        // finally committed, with its original speaker index intact.
        let (chunk1, watermark1) = MeetingDiarizationAttributor.attribute(
            segments: [], reportedThroughSample: 0, committedThroughSample: 6000,
            chunkStartGlobal: 0, chunkEndGlobal: 10000)
        #expect(chunk1.regions.isEmpty)
        #expect(chunk1.coveredThroughSample == 6000)

        // By chunk 2's cut, the diarizer has caught up and finally committed a segment that
        // started back in chunk 1's window (7000..12000) - attributing it to chunk 2 must clip
        // away the part before the watermark instead of re-showing all of it or none of it.
        let laterSegments: [(speaker: Int, start: Int, end: Int)] = [(3, 7000, 12000)]
        let (chunk2, _) = MeetingDiarizationAttributor.attribute(
            segments: laterSegments, reportedThroughSample: watermark1, committedThroughSample: 20000,
            chunkStartGlobal: 10000, chunkEndGlobal: 20000)
        #expect(chunk2.regions.count == 1)
        #expect(chunk2.regions[0].speaker == 3)
        // Global [7000, 12000) clipped to >= watermark (10000) then translated to chunk-local.
        #expect(chunk2.regions[0].start == 0 && chunk2.regions[0].end == 2000)
    }

    @Test func aSegmentAlreadyReportedIsNeverRepeatedInALaterChunk() {
        let segments: [(speaker: Int, start: Int, end: Int)] = [(0, 0, 5000)]
        let (_, watermark1) = MeetingDiarizationAttributor.attribute(
            segments: segments, reportedThroughSample: 0, committedThroughSample: 5000,
            chunkStartGlobal: 0, chunkEndGlobal: 5000)
        let (chunk2, _) = MeetingDiarizationAttributor.attribute(
            segments: segments, reportedThroughSample: watermark1, committedThroughSample: 5000,
            chunkStartGlobal: 5000, chunkEndGlobal: 10000)
        #expect(chunk2.regions.isEmpty)
    }

    @Test func fullyCoveredChunkReportsNoShortfall() {
        let (chunk, _) = MeetingDiarizationAttributor.attribute(
            segments: [], reportedThroughSample: 0, committedThroughSample: 999_999,
            chunkStartGlobal: 1000, chunkEndGlobal: 2000)
        #expect(chunk.coveredThroughSample == 1000)  // chunk-local: the whole chunk is covered
    }
}
