import Testing
@testable import VoiceInk

// MARK: - append/finish guard against Nemotron3Diarizer's "no append after finishStream" trap

struct MeetingDiarizerLifecycleTests {
    @Test func appendIsAllowedBeforeFinish() {
        #expect(MeetingDiarizer.shouldAppend(failed: false, finished: false, samplesEmpty: false))
    }

    @Test func appendAfterFinishIsANoOpNotATrap() {
        // Mirrors a manual chunk send's delayed `cut()` (see `MeetingAudioCapture.cutForManualSend`)
        // landing on `tapQueue` after `stop()` already called `MeetingDiarizer.finish()` - the
        // underlying `Nemotron3Diarizer.appendAudio` traps here; the guard must not forward the call.
        #expect(!MeetingDiarizer.shouldAppend(failed: false, finished: true, samplesEmpty: false))
    }

    @Test func finishIsIdempotent() {
        #expect(MeetingDiarizer.shouldFinish(failed: false, finished: false))
        #expect(!MeetingDiarizer.shouldFinish(failed: false, finished: true))
    }

    @Test func aFailedSessionNeverForwardsAppendOrFinish() {
        #expect(!MeetingDiarizer.shouldAppend(failed: true, finished: false, samplesEmpty: false))
        #expect(!MeetingDiarizer.shouldFinish(failed: true, finished: false))
    }
}

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

// MARK: - In-person mode: diarizing the mic channel instead of assuming it is all "Me"

struct MeetingTurnBuilderInPersonDiarizedSpeakerTests {
    private typealias Region = MeetingVAD.Region
    private typealias Turn = MeetingTurnBuilder.Turn
    private typealias Speaker = MeetingTurnBuilder.Speaker

    private func loud(_ count: Int) -> [Int16] {
        [Int16](repeating: 5000, count: count)
    }

    @Test func distinctMicDiarizedSpeakersProduceDistinctOrderedTurns() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000), Region(start: 2000, end: 3000)],
            othersRegions: [], meSamples: loud(3000), othersSamples: [],
            meSpeakers: [.otherMic(0), .otherMic(1)]
        )
        #expect(
            turns == [
                Turn(speaker: .otherMic(0), start: 0, end: 1000),
                Turn(speaker: .otherMic(1), start: 2000, end: 3000),
            ])
    }

    @Test func missingMeSpeakersArrayFallsBackToThePlainMeLabel() {
        // Pre-in-person behaviour: no `meSpeakers` array means the whole mic channel is "Me".
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000)], othersRegions: [], meSamples: loud(1000), othersSamples: []
        )
        #expect(turns == [Turn(speaker: .me, start: 0, end: 1000)])
    }

    @Test func meAndOtherMicAndOtherAreAllDistinctSpeakers() {
        // A mic-diarized non-"me" speaker (`.otherMic`) must never equal a system-diarized one
        // (`.other`) or plain "Me", even with the same underlying slot index - they are different
        // channels entirely (see `Speaker.isMicChannel`).
        #expect(Speaker.otherMic(0) != Speaker.other(0))
        #expect(Speaker.otherMic(0) != Speaker.me)
    }

    @Test func meAndOtherMicAreMicChannelOtherIsNot() {
        #expect(Speaker.me.isMicChannel)
        #expect(Speaker.otherMic(0).isMicChannel)
        #expect(Speaker.othersMic.isMicChannel)
        #expect(!Speaker.other(0).isMicChannel)
        #expect(!Speaker.others.isMicChannel)
    }

    @Test func anUncommittedMicTailWithNoAttributedRegionFallsBackToTheGenericOthersMicLabel() {
        typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn
        let rendered = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .otherMic(0), text: "hello"),
            TranscribedTurn(speaker: .othersMic, text: "unresolved tail"),
        ])
        #expect(rendered == "[spk-0000:] hello\n\n[Others:] unresolved tail")
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
        // Committed through 17000 only (3000 short of the chunk end, chunk-local 7000..10000) -
        // continuation extends speaker 1's region through the chunk end rather than leaving that
        // shortfall for a separate "Others" turn (see the tail-continuation tests below).
        #expect(chunk2.regions[0].start == 0 && chunk2.regions[0].end == 10000)
        #expect(chunk2.coveredThroughSample == 10000)
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

    // MARK: - Live-chunk tail continuation (never a separate, generically-labelled "Others" turn)

    @Test func anUncommittedTailWithAnAttributedRegionContinuesThatSpeakerThroughTheChunkEnd() {
        // Diarizer has only committed through 7000 by cut time (streaming latency, or the wait in
        // `MeetingAudioCapture.waitForDiarizerCommit` timing out) - speaker 2 talked [1000, 6000),
        // and the last ~3000 samples of the chunk are still uncommitted. That tail must extend
        // speaker 2's turn through the chunk end, not surface as a separate "Others" turn.
        let (chunk, _) = MeetingDiarizationAttributor.attribute(
            segments: [(2, 1000, 6000)], reportedThroughSample: 0, committedThroughSample: 7000,
            chunkStartGlobal: 0, chunkEndGlobal: 10000)
        #expect(chunk.regions.count == 1)
        #expect(chunk.regions[0].speaker == 2)
        #expect(chunk.regions[0].start == 1000 && chunk.regions[0].end == 10000)
        // Fully covered from the caller's perspective - no VAD fallback for the uncommitted tail.
        #expect(chunk.coveredThroughSample == 10000)
    }

    @Test func anUncommittedTailWithNoAttributedRegionAtAllStillReportsTheShortfall() {
        // No speech has been attributed in this chunk yet (diarizer failed before computing any,
        // or genuinely hasn't caught up) - nothing to continue, so the real shortfall must still
        // be reported for the caller's VAD/"Others" fallback (see
        // `aSegmentNotYetCommittedByCutTimeIsDeferredToTheNextChunkNotDropped` above for the
        // deferred-to-next-chunk half of this case).
        let (chunk, _) = MeetingDiarizationAttributor.attribute(
            segments: [], reportedThroughSample: 0, committedThroughSample: 4000,
            chunkStartGlobal: 0, chunkEndGlobal: 10000)
        #expect(chunk.regions.isEmpty)
        #expect(chunk.coveredThroughSample == 4000)
    }
}

// MARK: - Labelling VAD regions with diarized speakers (WHAT stays VAD's job, WHO is the diarizer's)

struct MeetingDiarizationLabelerTests {
    private typealias Region = MeetingVAD.Region
    private typealias Speaker = MeetingTurnBuilder.Speaker

    private func loud(_ count: Int) -> [Int16] {
        [Int16](repeating: 5000, count: count)
    }

    @Test func aRegionWithNoInternalPauseIsLabelledByMajorityOverlapWithoutSplitting() {
        // Diarizer says speaker 0 for the first 12000 samples, speaker 1 for the last 8000 - but
        // the region itself never pauses, so the VAD region must stay whole (never cut mid-word)
        // and take the speaker with the larger overlap.
        let (regions, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: [Region(start: 0, end: 20000)],
            diarizedSegments: [(speaker: 0, start: 0, end: 12000), (speaker: 1, start: 12000, end: 20000)],
            samples: loud(20000), speakerForSlot: { .other($0) }, noSpeaker: .others)
        #expect(regions == [Region(start: 0, end: 20000)])
        #expect(speakers == [.other(0)])
    }

    @Test func aSpeakerChangeCoincidingWithARealPauseSplitsTheRegion() {
        // A diarizer speaker change at 10000 lands inside a real (>= 200 ms) pause the VAD region
        // itself contains - the region must split there, each half taking its own speaker.
        let samples = loud(8960) + [Int16](repeating: 0, count: 4160) + loud(20000 - 8960 - 4160)
        let (regions, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: [Region(start: 0, end: 20000)],
            diarizedSegments: [(speaker: 0, start: 0, end: 10000), (speaker: 1, start: 10000, end: 20000)],
            samples: samples, speakerForSlot: { .other($0) }, noSpeaker: .others)
        #expect(regions.count == 2)
        #expect(speakers == [.other(0), .other(1)])
        #expect(regions[0].start == 0 && regions[1].end == 20000)
        #expect(regions[0].end == regions[1].start)
        // The split lands inside the pause and within the 0.5 s tolerance of the diarizer's
        // change point (10000) - not hardcoded to the pause's exact midpoint.
        #expect(regions[0].end >= 8960 && regions[0].end <= 13120)
        #expect(abs(regions[0].end - 10000) <= Int(0.5 * MeetingVAD.sampleRate))
        // Nothing dropped: the split regions still cover exactly the original region's span.
        #expect(regions.reduce(0) { $0 + ($1.end - $1.start) } == 20000)
    }

    @Test func aGapWithNoDiarizerOverlapInheritsThePreviousRegionsSpeaker() {
        let (_, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: [Region(start: 0, end: 1000), Region(start: 2000, end: 3000), Region(start: 4000, end: 5000)],
            diarizedSegments: [(speaker: 0, start: 0, end: 1000), (speaker: 1, start: 4000, end: 5000)],
            samples: loud(5000), speakerForSlot: { .other($0) }, noSpeaker: .others)
        #expect(speakers == [.other(0), .other(0), .other(1)])
    }

    @Test func aLeadingGapWithNoDiarizerOverlapTakesTheNextRegionsSpeaker() {
        let (_, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: [Region(start: 0, end: 1000), Region(start: 2000, end: 3000)],
            diarizedSegments: [(speaker: 1, start: 2000, end: 3000)],
            samples: loud(3000), speakerForSlot: { .other($0) }, noSpeaker: .others)
        #expect(speakers == [.other(1), .other(1)])
    }

    @Test func noDiarizerOverlapAnywhereFallsBackToTheGenericOthersLabel() {
        let (_, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: [Region(start: 0, end: 1000)], diarizedSegments: [], samples: loud(1000),
            speakerForSlot: { .other($0) }, noSpeaker: .others)
        #expect(speakers == [.others])
    }
}

// MARK: - Regression: a live chunk's speaker labels must survive `TranscriptionPipeline.run`
//
// The pipeline's Whisper hallucination filter strips `\[.*?\]` (e.g. `[BLANK_AUDIO]`) from raw
// model output. Meeting capture hands its already-rendered, speaker-labelled text
// ("[Me:] ...", "[spk-0001:] ...") in as `pretranscribedText`; running that same filter on it
// silently erased every speaker label, merging every paragraph into one unlabelled block - the
// live-chunk-paste regression this pins.

@MainActor
struct PretranscribedMeetingTextSkipsTheHallucinationFilterTests {
    @Test func aDiarizedMeetingChunksRenderedLabelsSurviveThePipelinesPostProcessing() {
        typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn
        let rendered = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .me, text: "hello"),
            TranscribedTurn(speaker: .other(0), text: "hey there"),
            TranscribedTurn(speaker: .other(1), text: "hi everyone"),
        ])

        let posted = TranscriptionPipeline.postTranscriptionText(
            pretranscribedText: rendered, transcribedText: rendered)

        #expect(posted.contains("[Me:]"))
        #expect(posted.contains("[spk-0000:]"))
        #expect(posted.contains("[spk-0001:]"))
        #expect(posted == rendered)
    }

    @Test func rawModelOutputStillGetsItsHallucinationBracketsStripped() {
        let posted = TranscriptionPipeline.postTranscriptionText(
            pretranscribedText: nil, transcribedText: "[BLANK_AUDIO] actual words")
        #expect(!posted.contains("[BLANK_AUDIO]"))
        #expect(posted == "actual words")
    }
}
