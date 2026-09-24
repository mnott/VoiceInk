import Testing
@testable import VoiceInk

struct MeetingTurnBuilderTests {
    private typealias Region = MeetingVAD.Region
    private typealias Turn = MeetingTurnBuilder.Turn

    private func loud(_ count: Int) -> [Int16] {
        [Int16](repeating: 5000, count: count)
    }

    private func quiet(_ count: Int) -> [Int16] {
        [Int16](repeating: 0, count: count)
    }

    @Test func sequentialNonOverlappingRegionsAreOrderedByStart() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000)],
            othersRegions: [Region(start: 2000, end: 3000)],
            meSamples: loud(1000), othersSamples: loud(3000)
        )
        #expect(turns == [Turn(speaker: .me, start: 0, end: 1000), Turn(speaker: .others, start: 2000, end: 3000)])
    }

    @Test func anInterjectionWithANearbyInternalPauseSplitsTheHostAtThePause() {
        // Others talks [0, 32000) with a 240 ms (3840-sample, frame-aligned so the pause's
        // detected boundaries are exact) dip at [13440, 17280); Me interjects [15000, 16000),
        // right next to that dip.
        let othersSamples = loud(13440) + quiet(3840) + loud(32000 - 17280)
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 15000, end: 16000)],
            othersRegions: [Region(start: 0, end: 32000)],
            meSamples: loud(16000), othersSamples: othersSamples
        )
        #expect(
            turns == [
                Turn(speaker: .others, start: 0, end: 15360),
                Turn(speaker: .me, start: 15000, end: 16000),
                Turn(speaker: .others, start: 15360, end: 32000),
            ])
    }

    @Test func anInterjectionWithNoNearbyPauseKeepsTheHostWholeAndPlacesItAfter() {
        // Others talks [0, 20000) with no pause anywhere inside; Me interjects [10000, 11000).
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 10000, end: 11000)],
            othersRegions: [Region(start: 0, end: 20000)],
            meSamples: loud(11000), othersSamples: loud(20000)
        )
        #expect(
            turns == [
                Turn(speaker: .others, start: 0, end: 20000),
                Turn(speaker: .me, start: 10000, end: 11000),
            ])
    }

    /// The echo-leak regression (2026-09-24): a sustained, multi-second interjector - the shape of
    /// uncancelled acoustic echo bleeding the host's own words back into the other channel, not a
    /// brief "yeah"/"I agree" - must never split the host, even when a perfectly good nearby pause
    /// exists (the same pause `anInterjectionWithANearbyInternalPauseSplitsTheHostAtThePause` would
    /// split on for a short interjector). Splitting the host here would hand its second half to the
    /// transcriber as a clip with no natural lead-in right where the interjector starts - exactly
    /// where ASR reliably drops the opening word(s), the mechanism behind the host "losing" words
    /// whenever a loud echo happens to land right where the host briefly pauses.
    @Test func aLongInterjectorNeverSplitsTheHostEvenWithANearbyPause() {
        // Others talks [0, 320000) with a 240 ms dip at [78400, 82240), right next to where Me's
        // 10 s (160000-sample) interjection starts at 80000 - well over maxSplittableInterjectorSamples.
        let othersSamples = loud(78400) + quiet(3840) + loud(320000 - 82240)
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 80000, end: 240000)],
            othersRegions: [Region(start: 0, end: 320000)],
            meSamples: loud(240000), othersSamples: othersSamples
        )
        #expect(
            turns == [
                Turn(speaker: .others, start: 0, end: 320000),
                Turn(speaker: .me, start: 80000, end: 240000),
            ])
    }

    @Test func consecutiveSameSpeakerTurnsWithASmallGapAreMerged() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000), Region(start: 1500, end: 2500)],
            othersRegions: [],
            meSamples: loud(2500), othersSamples: []
        )
        #expect(turns == [Turn(speaker: .me, start: 0, end: 2500)])
    }

    @Test func sameSpeakerTurnsWithALargeGapAreNotMerged() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000), Region(start: 20000, end: 21000)],
            othersRegions: [],
            meSamples: loud(21000), othersSamples: []
        )
        #expect(turns == [Turn(speaker: .me, start: 0, end: 1000), Turn(speaker: .me, start: 20000, end: 21000)])
    }

    @Test func sameSpeakerTurnsAreNotMergedAcrossAnInterveningOtherSpeakerTurn() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 1000), Region(start: 2000, end: 3000)],
            othersRegions: [Region(start: 1200, end: 1400)],
            meSamples: loud(3000), othersSamples: loud(1400)
        )
        #expect(
            turns == [
                Turn(speaker: .me, start: 0, end: 1000),
                Turn(speaker: .others, start: 1200, end: 1400),
                Turn(speaker: .me, start: 2000, end: 3000),
            ])
    }

    @Test func aTurnLongerThanTheCapIsSplitAtTheLongestInternalPause() {
        // 30 s of speech with a 250 ms pause around the 20 s mark (inside the 25 s cap window).
        let samples = loud(318_000) + quiet(4000) + loud(480_000 - 322_000)
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 480_000)],
            othersRegions: [],
            meSamples: samples, othersSamples: []
        )
        #expect(
            turns == [
                Turn(speaker: .me, start: 0, end: 320_000),
                Turn(speaker: .me, start: 320_000, end: 480_000),
            ])
    }

    @Test func aTurnLongerThanTheCapWithNoPauseIsHardCutAtTheCap() {
        let turns = MeetingTurnBuilder.build(
            meRegions: [Region(start: 0, end: 450_000)],
            othersRegions: [],
            meSamples: loud(450_000), othersSamples: []
        )
        #expect(
            turns == [
                Turn(speaker: .me, start: 0, end: 400_000),
                Turn(speaker: .me, start: 400_000, end: 450_000),
            ])
    }

    @Test func emptyInputProducesNoTurns() {
        #expect(MeetingTurnBuilder.build(meRegions: [], othersRegions: [], meSamples: [], othersSamples: []).isEmpty)
    }

    // MARK: - mergeAdjacentSameSpeakerForTranscription (the "sagen. können" fix)

    /// The exact shape `cap()` produces for one long uninterrupted utterance: same-speaker turns
    /// tiled back to back with zero gap. `MeetingTurnTranscriber` must send them to the ASR as one
    /// clip, or the ASR closes each piece with its own sentence-ending punctuation mid-sentence.
    @Test func capSplitPiecesOfTheSameSpeakerWithNoGapAreMergedForTranscription() {
        let turns = [
            Turn(speaker: .others, start: 0, end: 400_000),
            Turn(speaker: .others, start: 400_000, end: 800_000),
            Turn(speaker: .others, start: 800_000, end: 900_000),
        ]
        #expect(
            MeetingTurnBuilder.mergeAdjacentSameSpeakerForTranscription(turns) == [
                Turn(speaker: .others, start: 0, end: 900_000)
            ])
    }

    @Test func sameSpeakerTurnsWithAGapUpToOnePointFiveSecondsAreMergedForTranscription() {
        let gap = MeetingTurnBuilder.transcriptionMergeGapSamples
        let turns = [
            Turn(speaker: .others, start: 0, end: 100_000),
            Turn(speaker: .others, start: 100_000 + gap, end: 200_000 + gap),
        ]
        #expect(
            MeetingTurnBuilder.mergeAdjacentSameSpeakerForTranscription(turns) == [
                Turn(speaker: .others, start: 0, end: 200_000 + gap)
            ])
    }

    @Test func sameSpeakerTurnsWithAGapOverOnePointFiveSecondsAreNotMergedForTranscription() {
        let gap = MeetingTurnBuilder.transcriptionMergeGapSamples + 1
        let turns = [
            Turn(speaker: .others, start: 0, end: 100_000),
            Turn(speaker: .others, start: 100_000 + gap, end: 200_000 + gap),
        ]
        #expect(MeetingTurnBuilder.mergeAdjacentSameSpeakerForTranscription(turns) == turns)
    }

    /// A genuine speaker change must never be bridged into one clip, no matter how small the gap.
    @Test func differentSpeakerNeighboursAreNeverMergedForTranscription() {
        let turns = [
            Turn(speaker: .others, start: 0, end: 100_000),
            Turn(speaker: .me, start: 100_000, end: 200_000),
            Turn(speaker: .others, start: 200_000, end: 300_000),
        ]
        #expect(MeetingTurnBuilder.mergeAdjacentSameSpeakerForTranscription(turns) == turns)
    }
}
