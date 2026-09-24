import Testing

@testable import VoiceInk

struct MeetingMicSpeakerMapperTests {
    @Test func unresolvedSlotShowsTheFallback() {
        let label = MeetingMicSpeakerMapper.label(libraryID: nil, isMeVoice: { _ in false }, fallback: "spk-0001")
        #expect(label == "spk-0001")
    }

    @Test func resolvedSlotMatchingTheMeVoiceShowsMe() {
        let label = MeetingMicSpeakerMapper.label(
            libraryID: "spk-me", isMeVoice: { $0 == "spk-me" }, fallback: "spk-0001")
        #expect(label == "Me")
    }

    @Test func resolvedSlotNotMatchingTheMeVoiceShowsTheFallback() {
        // A named ("Anna") or still-unnamed ("spk-xxxx") non-"me" match - either way, not "Me".
        let label = MeetingMicSpeakerMapper.label(libraryID: "spk-anna", isMeVoice: { $0 == "spk-me" }, fallback: "Anna")
        #expect(label == "Anna")
    }

    @Test func noMeVoiceEnrolledAtAllNeverAssumesAnySlotIsMe() {
        // The "never assume" requirement: with no library voice flagged `isMe`, `isMeVoice` is
        // false for every id, so every slot - however dominant - keeps its resolved name/id.
        let neverMe: (String) -> Bool = { _ in false }
        #expect(MeetingMicSpeakerMapper.label(libraryID: "spk-a", isMeVoice: neverMe, fallback: "spk-a") == "spk-a")
        #expect(MeetingMicSpeakerMapper.label(libraryID: "spk-b", isMeVoice: neverMe, fallback: "Bob") == "Bob")
    }
}
