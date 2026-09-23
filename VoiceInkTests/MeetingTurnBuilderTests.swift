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
}
