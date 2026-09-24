import Foundation

/// Renders a `MeetingTurnBuilder`-ordered list of transcribed turns into speaker-labelled text,
/// e.g.:
///
///     [Me:] ...
///     [Others:] ...
///     [Me:] ...
///
/// The turns are already in the right order (`MeetingTurnBuilder` resolved interjections), so
/// this only needs to drop empties and merge consecutive same-speaker turns into one paragraph -
/// the same merge `MeetingTranscriptInterleaver` used to do from window start times.
///
/// A diarized `.other(index)` gets a `spk-XXXX` tag derived from its arrival-ordered index alone,
/// unless `render`'s `liveLabel` resolves it to a name - see `MeetingLiveSpeakerTracker`, which
/// live-matches a slot against the persistent speaker library (or names it via the "Name Speaker"
/// hotkey) as a session progresses. The session id itself is still only stable within one capture
/// session, and unrelated to any library `spk-` id of the same-looking speaker once the whole-
/// meeting note re-identifies them from scratch after capture stops.
enum MeetingTurnTranscriptRenderer {
    struct TranscribedTurn: Equatable {
        let speaker: MeetingTurnBuilder.Speaker
        let text: String
        /// The turn's span in session-global samples (see `MeetingTurnBuilder.Turn`), used by
        /// `MeetingEchoSafetyNet` to find Me/Others turns that overlap in time. Defaults to `0..<0`
        /// (no known span) for callers - mostly tests - that only care about rendering.
        let start: Int
        let end: Int

        init(speaker: MeetingTurnBuilder.Speaker, text: String, start: Int = 0, end: Int = 0) {
            self.speaker = speaker
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// - Parameter liveLabel: Once a diarized slot (system-channel `.other` or, in an in-person
    ///   meeting, mic-channel `.otherMic` - see `MeetingCaptureModeDetector`) has been live-matched
    ///   against the speaker library (or named via the "Name Speaker" hotkey - see
    ///   `MeetingLiveSpeakerTracker`/`MeetingMicSpeakerMapper`), this returns its current label
    ///   instead of the raw `spk-XXXX` session id/generic fallback; `nil` for any speaker this
    ///   callback doesn't resolve, e.g. `.me`, falls through to the default below. `nil` (the
    ///   default) keeps every slot's session id, e.g. for callers - mostly tests - with no live
    ///   session.
    static func render(
        _ turns: [TranscribedTurn], liveLabel: (MeetingTurnBuilder.Speaker) -> String? = { _ in nil }
    ) -> String {
        var paragraphs: [(speaker: MeetingTurnBuilder.Speaker, texts: [String])] = []
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if paragraphs.last?.speaker == turn.speaker {
                paragraphs[paragraphs.count - 1].texts.append(text)
            } else {
                paragraphs.append((turn.speaker, [text]))
            }
        }

        return paragraphs.map { paragraph -> String in
            "[\(label(for: paragraph.speaker, liveLabel: liveLabel)):] \(paragraph.texts.joined(separator: " "))"
        }.joined(separator: "\n\n")
    }

    private static func label(
        for speaker: MeetingTurnBuilder.Speaker, liveLabel: (MeetingTurnBuilder.Speaker) -> String?
    ) -> String {
        if let live = liveLabel(speaker) { return live }
        switch speaker {
        case .me: return String(localized: "Me")
        case .other(nil), .otherMic(nil): return String(localized: "Others")
        case .other(let index?), .otherMic(let index?): return String(format: "spk-%04x", index)
        }
    }
}
