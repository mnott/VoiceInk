import Foundation

/// One persisted turn of a meeting History record's structured transcript - the source of truth
/// `text` is rendered from (see `MeetingSpeakerTranscriptRenderer`), never hand-edited for names.
/// `start`/`end` are meeting-global sample offsets (16 kHz) into the record's stored stereo audio
/// - the mic channel for `isMe` turns, the system channel otherwise - so a later pass (Identify
/// Speakers, embedding extraction) can slice the exact clip straight out of `audioFileURL` without
/// re-running VAD/turn-building.
struct MeetingTurnRecord: Codable, Equatable {
    var isMe: Bool
    /// Arrival-ordered diarization cluster index from the session that produced this turn, or
    /// `nil` when diarization did not run (or hadn't committed yet) for this stretch of audio -
    /// the pre-diarization/fallback "Others" case. Not shown to the user; used only to group a
    /// meeting's turns back into one clip-set per voice for embedding extraction/matching.
    var diarizedSlot: Int?
    /// Persistent speaker-library id (`spk-XXXX`), assigned once a voice has been identified
    /// (matched or newly registered) - see `MeetingSpeakerIdentifier`. `nil` until then, which
    /// renders as the generic "Others" label regardless of `diarizedSlot`.
    var speakerID: String?
    var start: Int
    var end: Int
    var text: String

    init(isMe: Bool, diarizedSlot: Int?, speakerID: String?, start: Int, end: Int, text: String) {
        self.isMe = isMe
        self.diarizedSlot = diarizedSlot
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
    }

    /// Converts one session-local transcribed turn (see `MeetingTurnTranscriber`) into its
    /// persisted form, offsetting `start`/`end` from "samples since this transcription pass
    /// started" to "samples since the meeting started" - see
    /// `MeetingRecordingTranscriber.transcribe`, the only caller that needs the offset (a
    /// single, whole-meeting pass; the live per-chunk path never persists turns at all).
    init(_ turn: MeetingTurnTranscriptRenderer.TranscribedTurn, globalOffset: Int = 0) {
        switch turn.speaker {
        case .me:
            self.init(isMe: true, diarizedSlot: nil, speakerID: nil, start: turn.start + globalOffset, end: turn.end + globalOffset, text: turn.text)
        case .other(let slot):
            self.init(
                isMe: false, diarizedSlot: slot, speakerID: nil, start: turn.start + globalOffset, end: turn.end + globalOffset,
                text: turn.text)
        }
    }
}

/// Renders a meeting's structured turns into the `[Label:] text` transcript, resolving each turn's
/// `speakerID` against the speaker library's current name (or the id itself while unnamed) - the
/// single place "naming a voice updates every past transcript" runs from.
enum MeetingSpeakerTranscriptRenderer {
    static func render(_ turns: [MeetingTurnRecord], nameForSpeakerID: (String) -> String?) -> String {
        var paragraphs: [(label: String, texts: [String])] = []
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = label(for: turn, nameForSpeakerID: nameForSpeakerID)

            if paragraphs.last?.label == label {
                paragraphs[paragraphs.count - 1].texts.append(text)
            } else {
                paragraphs.append((label, [text]))
            }
        }

        return paragraphs.map { "[\($0.label):] \($0.texts.joined(separator: " "))" }.joined(separator: "\n\n")
    }

    private static func label(for turn: MeetingTurnRecord, nameForSpeakerID: (String) -> String?) -> String {
        if turn.isMe { return String(localized: "Me") }
        guard let speakerID = turn.speakerID else { return String(localized: "Others") }
        return nameForSpeakerID(speakerID) ?? speakerID
    }
}
