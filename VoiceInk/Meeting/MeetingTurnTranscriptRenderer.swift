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
/// A diarized `.other(index)` gets a `spk-XXXX` tag derived from its arrival-ordered index alone
/// (ponytail: not matched against the persistent speaker library - that only happens for the
/// whole-meeting note, built after capture stops; a live chunk is paste-only and never saved, so
/// there is no History record to attach a library match to yet). It is therefore stable only
/// within one capture session, and unrelated to any library `spk-` id of the same-looking speaker
/// once the meeting note re-identifies them - upgrade path is `MeetingDiarizationAttributor`
/// carrying a per-session salt through to here if live cross-session-looking ids become confusing
/// in practice.
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

    static func render(_ turns: [TranscribedTurn]) -> String {
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
            "[\(label(for: paragraph.speaker)):] \(paragraph.texts.joined(separator: " "))"
        }.joined(separator: "\n\n")
    }

    private static func label(for speaker: MeetingTurnBuilder.Speaker) -> String {
        switch speaker {
        case .me: return String(localized: "Me")
        case .other(nil): return String(localized: "Others")
        case .other(let index?): return String(format: "spk-%04x", index)
        }
    }
}
