import Foundation
import Testing

@testable import VoiceInk

/// The meeting re-transcribe path (`AudioTranscriptionService.retranscribeMeetingAudio`) must build
/// its `TranscriptionRequestContext` from the same dictation language source as every other path -
/// the active mode's `selectedLanguage`, validated for the model (`ModeRuntimeResolver`'s rule) -
/// instead of the raw `UserDefaults "SelectedLanguage"`/`"auto"` fallback it used before, which made
/// a fixed-language meeting's noisy shorttalk head re-transcribe in random languages. Builder-level
/// proof, no ASR run; both re-transcribe call sites share the builder, so it cannot drift.
@MainActor
struct MeetingRetranscribeLanguageTests {
    private let parakeet = FluidAudioModel(
        name: "parakeet-eow-ml", displayName: "Parakeet", description: "test", size: "s", speed: 1, accuracy: 1,
        ramUsage: 1, supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio))

    @Test func meetingRetranscriptionCarriesDictationLanguage() {
        let mode = ModeConfig(name: "Meetings", isAIEnhancementEnabled: false, selectedLanguage: "de")
        let context = AudioTranscriptionService.retranscriptionRequestContext(for: parakeet, mode: mode)

        #expect(context.language == "de", "meeting re-transcription must carry the dictation language, not autodetect")
        #expect(context.prompt == nil, "only Whisper models carry the transcription prompt")
    }

    @Test func languageSurvivesWhenModeOmitsIt() {
        // No usable mode language: the same builder must still yield the model-compatible
        // fallback ("auto" for multilingual Parakeet), never nil and never a mismatched language.
        let mode = ModeConfig(name: "Plain", isAIEnhancementEnabled: false, selectedLanguage: "xx-Invalid")
        let context = AudioTranscriptionService.retranscriptionRequestContext(for: parakeet, mode: mode)
        #expect(context.language == "auto")
    }

    @Test func whisperRetranscriptionKeepsPrompt() {
        let whisper = WhisperModel(
            name: "test-model", displayName: "test", size: "s",
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
            description: "test", speed: 1, accuracy: 1, ramUsage: 1)
        let mode = ModeConfig(name: "Dictation", isAIEnhancementEnabled: false, selectedLanguage: "de")
        UserDefaults.standard.set("prompt-text", forKey: "TranscriptionPrompt")
        defer { UserDefaults.standard.removeObject(forKey: "TranscriptionPrompt") }

        let context = AudioTranscriptionService.retranscriptionRequestContext(for: whisper, mode: mode)
        #expect(context.language == "de")
        #expect(context.prompt == "prompt-text")
    }
}
