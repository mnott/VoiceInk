import Foundation

/// Renders a `MeetingTurnBuilder`-ordered list of transcribed turns into speaker-labelled text,
/// e.g.:
///
///     Me: ...
///     Others: ...
///     Me: ...
///
/// The turns are already in the right order (`MeetingTurnBuilder` resolved interjections), so
/// this only needs to drop empties and merge consecutive same-speaker turns into one paragraph -
/// the same merge `MeetingTranscriptInterleaver` used to do from window start times.
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
            let label = paragraph.speaker == .me ? String(localized: "Me") : String(localized: "Others")
            return "\(label): \(paragraph.texts.joined(separator: " "))"
        }.joined(separator: "\n\n")
    }
}
