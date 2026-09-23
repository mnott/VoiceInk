import Testing
@testable import VoiceInk

struct MeetingDictationGateTests {
    @Test func passesMicThroughUnchangedWhenNoDictationIsActive() {
        let mic: [Int16] = [100, -200, 300, 0]
        #expect(MeetingDictationGate.silenceMicDuringDictation(mic, isDictationActive: false) == mic)
    }

    @Test func silencesTheWholeBufferWhileADictationRecordingIsActive() {
        let mic: [Int16] = [100, -200, 300, 0, 5000]
        let gated = MeetingDictationGate.silenceMicDuringDictation(mic, isDictationActive: true)
        #expect(gated == [Int16](repeating: 0, count: mic.count))
    }

    @Test func silencingAnEmptyBufferProducesAnEmptyBuffer() {
        #expect(MeetingDictationGate.silenceMicDuringDictation([], isDictationActive: true).isEmpty)
    }

    @MainActor
    @Test func dictationIsActiveFromRecordingStartThroughTranscriptionButNotDuringEnhancementOrIdle() {
        #expect(VoiceInkEngine.isDictationRecordingState(.starting))
        #expect(VoiceInkEngine.isDictationRecordingState(.recording))
        #expect(VoiceInkEngine.isDictationRecordingState(.transcribing))
        #expect(!VoiceInkEngine.isDictationRecordingState(.idle))
        #expect(!VoiceInkEngine.isDictationRecordingState(.enhancing))
        #expect(!VoiceInkEngine.isDictationRecordingState(.busy))
    }
}
