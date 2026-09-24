import Foundation

/// Resolves a mic-diarized speaker's render label (in-person mode - see
/// `MeetingCaptureModeDetector`), once the live tracker (`micSpeakerTracker`) has matched its
/// voice against the library. Never assumes a slot is "Me" from dominance, arrival order, or
/// anything but an explicit library match: if no voice in the library is flagged "this is me" (see
/// `SpeakerVoice.isMe`), `isMeVoice` is false for every id, so every mic speaker keeps rendering by
/// its resolved name/session id (`fallback`) - exactly the "don't assume" behaviour the caller
/// needs, with no extra branching required here.
enum MeetingMicSpeakerMapper {
    static func label(libraryID: String?, isMeVoice: (String) -> Bool, fallback: String) -> String {
        guard let libraryID, isMeVoice(libraryID) else { return fallback }
        return String(localized: "Me")
    }
}
