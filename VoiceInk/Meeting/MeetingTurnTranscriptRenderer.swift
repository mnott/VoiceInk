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
    struct TranscribedTurn {
        let speaker: MeetingTurnBuilder.Speaker
        let text: String
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
