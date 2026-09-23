import Testing
@testable import VoiceInk

struct MeetingTurnTranscriptRendererTests {
    private typealias TranscribedTurn = MeetingTurnTranscriptRenderer.TranscribedTurn

    @Test func rendersTurnsInTheGivenOrderWithSpeakerLabels() {
        let text = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .me, text: "hello"),
            TranscribedTurn(speaker: .others, text: "hi back"),
        ])
        #expect(text == "Me: hello\n\nOthers: hi back")
    }

    @Test func mergesConsecutiveSameSpeakerTurnsIntoOneParagraph() {
        let text = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .me, text: "one"),
            TranscribedTurn(speaker: .me, text: "two"),
            TranscribedTurn(speaker: .me, text: "three"),
        ])
        #expect(text == "Me: one two three")
    }

    @Test func doesNotMergeAcrossAnInterveningOtherSpeakerTurn() {
        let text = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .me, text: "one"),
            TranscribedTurn(speaker: .others, text: "interruption"),
            TranscribedTurn(speaker: .me, text: "two"),
        ])
        #expect(text == "Me: one\n\nOthers: interruption\n\nMe: two")
    }

    @Test func dropsEmptyOrWhitespaceOnlyTurns() {
        let text = MeetingTurnTranscriptRenderer.render([
            TranscribedTurn(speaker: .me, text: "hello"),
            TranscribedTurn(speaker: .others, text: "   "),
            TranscribedTurn(speaker: .me, text: "world"),
        ])
        #expect(text == "Me: hello world")
    }

    @Test func emptyInputProducesAnEmptyTranscript() {
        #expect(MeetingTurnTranscriptRenderer.render([]).isEmpty)
    }
}
