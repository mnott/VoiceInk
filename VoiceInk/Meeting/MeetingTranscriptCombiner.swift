import Foundation

/// Combines the mic and system-audio transcripts of a meeting chunk into the one text that gets
/// delivered. Kept separate from `VoiceInkEngine+Meeting` so the labeling/omission rules are
/// unit-testable without the pipeline around them.
enum MeetingTranscriptCombiner {
    /// - Parameters:
    ///   - micText: Raw transcript of the (echo-cancelled) microphone track, may be empty.
    ///   - systemText: Raw transcript of the system-audio track, may be empty.
    ///   - isCapturingSystemAudio: Whether this capture session has a system-audio tap at all. If
    ///     false, `systemText` is ignored and the mic text is returned unlabeled, as it always
    ///     was before per-speaker labeling existed.
    static func combine(micText: String, systemText: String, isCapturingSystemAudio: Bool) -> String {
        let mic = micText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCapturingSystemAudio else { return mic }

        let system = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if !mic.isEmpty {
            lines.append(String(format: String(localized: "Me: %@"), mic))
        }
        if !system.isEmpty {
            lines.append(String(format: String(localized: "Others: %@"), system))
        }
        return lines.joined(separator: "\n")
    }
}
