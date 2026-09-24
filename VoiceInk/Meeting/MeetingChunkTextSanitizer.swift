import Foundation

/// Meeting chunk text is *other people's* speech, pasted verbatim into whatever destination is
/// pinned - often a shell or agent REPL where a line starting with `/`, `!` or `#` runs a command
/// instead of being read as text. A speaker saying "slash quit" must not be able to end a call.
///
/// Every line (a chunk's rendered text can be multi-line: multiple speaker paragraphs, or a
/// transcript containing a literal newline) whose first non-whitespace character is one of those
/// three is prefixed, right at that character, with "› " - visible enough to show something was
/// altered, neutral enough not to read as part of the transcript. A speaker-label line always
/// starts with `[` (see `MeetingTurnTranscriptRenderer`) so it is never touched by this.
///
/// Not used by dictation or any other `PinnedDestinationManager` delivery path - those are text
/// the *user* chose to paste, including deliberate slash commands, and must reach the destination
/// unchanged. Called only from the meeting-chunk delivery path in `VoiceInkEngine+Meeting`.
enum MeetingChunkTextSanitizer {
    private static let neutralMarker = "› "
    private static let triggerCharacters: Set<Character> = ["/", "!", "#"]

    static func sanitize(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(sanitizeLine)
            .joined(separator: "\n")
    }

    private static func sanitizeLine(_ line: Substring) -> String {
        guard let firstNonSpaceIndex = line.firstIndex(where: { $0 != " " && $0 != "\t" }),
            triggerCharacters.contains(line[firstNonSpaceIndex])
        else {
            return String(line)
        }
        var sanitized = line
        sanitized.insert(contentsOf: neutralMarker, at: firstNonSpaceIndex)
        return String(sanitized)
    }
}
