import Testing
import Foundation
@testable import VoiceInk

/// `MeetingEchoSafetyNet`: text-level echo removal for what `EchoCanceller` leaves behind.
struct MeetingEchoSafetyNetTests {
    private typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn
    private static let sampleRate = Int(MeetingVAD.sampleRate)

    private func seconds(_ s: Double) -> Int { Int(s * Double(Self.sampleRate)) }

    @Test func aMeTurnThatIsEntirelyALeakedEchoOfTheOverlappingOthersTurnsIsDropped() {
        // The live-meeting example: a short Others turn immediately followed by a long Me turn
        // that is actually the other side's speech leaking through, followed by (a VAD-pause-
        // split continuation of) the same Others speech, digits spoken as number words on one
        // side and as digits on the other.
        let others1 = TranscribedTurn(
            speaker: .others, text: "The second supplier.", start: seconds(0), end: seconds(1.5))
        let me = TranscribedTurn(
            speaker: .me,
            text:
                "The second supplier, the packaging company, raised prices by 7%. Their argument is the cost of recycled cardboard. I asked for a comparison offer, they will get back to us in three weeks instead of 10 days.",
            start: seconds(1.5), end: seconds(9))
        let others2 = TranscribedTurn(
            speaker: .others,
            text:
                "The packaging company raised prices by 7%. Their argument is the cost of recycled cardboard. I asked for a comparison offer, they will get back to us in 3 weeks instead of ten days.",
            start: seconds(9.2), end: seconds(16))

        let result = MeetingEchoSafetyNet.filter([others1, me, others2])

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.speaker == .others })
    }

    @Test func genuineDoubleTalkWithDifferentWordsSurvivesUnchanged() {
        let others = TranscribedTurn(
            speaker: .others, text: "Let's move on to the next topic then.", start: seconds(0), end: seconds(3))
        let me = TranscribedTurn(
            speaker: .me, text: "I agree, that's a good idea.", start: seconds(0.5), end: seconds(2))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.count == 2)
        #expect(result.first { $0.speaker == .me }?.text == me.text)
    }

    @Test func aLeakedEchoPrefixIsStrippedButTheSpeakersOwnTrailingWordsSurvive() {
        let others = TranscribedTurn(
            speaker: .others, text: "The packaging company raised prices by 7% right",
            start: seconds(0), end: seconds(3))
        let me = TranscribedTurn(
            speaker: .me, text: "The packaging company raised prices by 7% that seems reasonable to me actually",
            start: seconds(0.2), end: seconds(4))

        let result = MeetingEchoSafetyNet.filter([others, me])

        let meResult = result.first { $0.speaker == .me }
        #expect(meResult?.text == "that seems reasonable to me actually")
    }

    @Test func aMeTurnWithNoTimeOverlapWithAnyOthersTurnIsNeverTouchedEvenIfWordsMatch() {
        let others = TranscribedTurn(
            speaker: .others, text: "The packaging company raised prices by 7 percent overall this year",
            start: seconds(0), end: seconds(3))
        let me = TranscribedTurn(
            speaker: .me, text: "The packaging company raised prices by 7 percent overall this year",
            start: seconds(30), end: seconds(33))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.first { $0.speaker == .me }?.text == me.text)
    }

    @Test func othersTurnsAreNeverFilteredOrDropped() {
        let others = TranscribedTurn(speaker: .others, text: "hello", start: seconds(0), end: seconds(1))
        let result = MeetingEchoSafetyNet.filter([others])
        #expect(result == [others])
    }

    @Test func numberWordsAndDigitsAreTreatedAsEqualForMatchingPurposes() {
        let others = TranscribedTurn(
            speaker: .others, text: "we need three weeks not ten days", start: seconds(0), end: seconds(2))
        let me = TranscribedTurn(
            speaker: .me, text: "we need 3 weeks not 10 days", start: seconds(0.1), end: seconds(2))

        let result = MeetingEchoSafetyNet.filter([others, me])

        // Every word matches once digits and number words are normalised to the same form, so
        // nothing survives the 3-word remainder floor and the whole turn is dropped.
        #expect(result.count == 1)
        #expect(result.first?.speaker == .others)
    }

    @Test func aGapWithinTheOneSecondSlackStillCountsAsOverlapAndGetsStripped() {
        let others = TranscribedTurn(
            speaker: .others, text: "The packaging company raised prices by 7 percent this year",
            start: seconds(0), end: seconds(2))
        // Starts 0.6 s after Others ends - within the 1 s slack, so this still counts as overlap.
        let me = TranscribedTurn(
            speaker: .me, text: "The packaging company raised prices by 7 percent this year",
            start: seconds(2.6), end: seconds(4.5))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.count == 1)
        #expect(result.first?.speaker == .others)
    }

    // MARK: - Live test 03:48: short/fuzzy echoes the exact-run stripping used to miss

    @Test func aShortMeTurnThatIsEntirelyAnEchoOfAShortOthersTurnIsDropped() {
        let others = TranscribedTurn(
            speaker: .others, text: "Good evening everyone.", start: seconds(0), end: seconds(1.5))
        let me = TranscribedTurn(
            speaker: .me, text: "Good evening everyone.", start: seconds(1.6), end: seconds(2.5))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.count == 1)
        #expect(result.first?.speaker == .others)
    }

    @Test func aShortMeTurnThatIsAnAsrVariantEchoIsDroppedViaFuzzyMatching() {
        let others = TranscribedTurn(
            speaker: .others, text: "the bowcode scans still drop about 2% of the reads",
            start: seconds(0), end: seconds(3))
        let me = TranscribedTurn(
            speaker: .me, text: "buckhold scanner still dropped", start: seconds(0.5), end: seconds(2))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.count == 1)
        #expect(result.first?.speaker == .others)
    }

    @Test func aShortMeTurnEchoingTwoSurroundingOthersTurnsIsDropped() {
        let othersBefore = TranscribedTurn(
            speaker: .others, text: "Understood.", start: seconds(0), end: seconds(0.8))
        let me = TranscribedTurn(
            speaker: .me, text: "Understood. Next topic.", start: seconds(0.9), end: seconds(1.8))
        let othersAfter = TranscribedTurn(
            speaker: .others, text: "Next topic, the budget is at seventy percent.",
            start: seconds(1.9), end: seconds(3.5))

        let result = MeetingEchoSafetyNet.filter([othersBefore, me, othersAfter])

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.speaker == .others })
    }

    @Test func genuineDoubleTalkOnAShortMeTurnSurvivesEvenWithSomeFuzzyOverlap() {
        let others = TranscribedTurn(
            speaker: .others, text: "the budget is at seventy percent", start: seconds(0), end: seconds(2.5))
        let me = TranscribedTurn(
            speaker: .me, text: "yes I agree with that", start: seconds(0.3), end: seconds(2))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.first { $0.speaker == .me }?.text == me.text)
    }

    @Test func aShortMeTurnWithNoOverlappingOthersTurnSurvivesEvenIfItWouldOtherwiseLookLikeAnEcho() {
        let unrelatedOthers = TranscribedTurn(
            speaker: .others, text: "Understood, moving on to the next item.", start: seconds(10), end: seconds(12))
        let me = TranscribedTurn(speaker: .me, text: "Understood.", start: seconds(0), end: seconds(0.8))

        let result = MeetingEchoSafetyNet.filter([me, unrelatedOthers])

        #expect(result.first { $0.speaker == .me }?.text == me.text)
    }

    @Test func aGapBeyondTheOneSecondSlackDoesNotCountAsOverlapEvenIfWordsMatch() {
        let others = TranscribedTurn(
            speaker: .others, text: "The packaging company raised prices by 7 percent this year",
            start: seconds(0), end: seconds(2))
        // Starts 1.4 s after Others ends - outside the 1 s slack, so no overlap and no stripping.
        let me = TranscribedTurn(
            speaker: .me, text: "The packaging company raised prices by 7 percent this year",
            start: seconds(3.4), end: seconds(5))

        let result = MeetingEchoSafetyNet.filter([others, me])

        #expect(result.first { $0.speaker == .me }?.text == me.text)
    }
}
