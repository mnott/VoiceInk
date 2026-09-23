import Testing
@testable import VoiceInk

struct MeetingTranscriptCombinerTests {
    @Test func combinesBothTracksWithLabelsWhenSystemAudioIsCaptured() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "hello there", systemText: "hi back", isCapturingSystemAudio: true)
        #expect(combined == "Me: hello there\nOthers: hi back")
    }

    @Test func omitsTheOthersLineWhenTheSystemTrackIsEmpty() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "hello there", systemText: "", isCapturingSystemAudio: true)
        #expect(combined == "Me: hello there")
    }

    @Test func omitsTheMeLineWhenTheMicTrackIsEmpty() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "", systemText: "hi back", isCapturingSystemAudio: true)
        #expect(combined == "Others: hi back")
    }

    @Test func omitsAWhitespaceOnlyTrackJustLikeAnEmptyOne() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "hello there", systemText: "   \n  ", isCapturingSystemAudio: true)
        #expect(combined == "Me: hello there")
    }

    @Test func returnsEmptyWhenBothTracksAreEmpty() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "", systemText: "", isCapturingSystemAudio: true)
        #expect(combined.isEmpty)
    }

    @Test func deliversPlainMicTextWithoutLabelsWhenSystemAudioIsNotBeingCaptured() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "hello there", systemText: "should be ignored", isCapturingSystemAudio: false)
        #expect(combined == "hello there")
    }

    @Test func trimsWhitespaceFromTheMicTextWhenSystemAudioIsNotBeingCaptured() {
        let combined = MeetingTranscriptCombiner.combine(
            micText: "  hello there  ", systemText: "", isCapturingSystemAudio: false)
        #expect(combined == "hello there")
    }
}
