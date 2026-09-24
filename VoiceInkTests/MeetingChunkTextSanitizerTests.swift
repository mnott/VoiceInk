import Foundation
import Testing
@testable import VoiceInk

struct MeetingChunkTextSanitizerTests {
    @Test func prefixesASlashCommandLine() {
        #expect(MeetingChunkTextSanitizer.sanitize("/quit") == "› /quit")
    }

    @Test func prefixesAShellCommandLineAfterLeadingWhitespace() {
        #expect(MeetingChunkTextSanitizer.sanitize("  !rm -rf x") == "  › !rm -rf x")
    }

    @Test func prefixesAMemoryWriteLine() {
        #expect(MeetingChunkTextSanitizer.sanitize("#note") == "› #note")
    }

    @Test func sanitizesOnlyTheUnsafeContinuationLineNotTheSpeakerLabel() {
        let sanitized = MeetingChunkTextSanitizer.sanitize("[spk-1a2b:] hello\n/clear")
        #expect(sanitized == "[spk-1a2b:] hello\n› /clear")
    }

    @Test func leavesNormalTextUnchanged() {
        #expect(MeetingChunkTextSanitizer.sanitize("hello there, how are you?") == "hello there, how are you?")
    }

    @Test func leavesAnUnlabelledSingleSpeakerLineUnchangedWhenItIsSafe() {
        #expect(MeetingChunkTextSanitizer.sanitize("let's meet at 3pm") == "let's meet at 3pm")
    }

    /// Dictation (and every other `PinnedDestinationManager` delivery) must keep letting the user
    /// deliberately dictate a slash command like "/clear" unchanged - so this sanitizer must never
    /// be referenced from the shared delivery layer, only from the meeting-chunk path that calls it
    /// explicitly in `VoiceInkEngine+Meeting`.
    @Test func isNeverReferencedFromPinnedDestinationManager() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let pinnedDestinationManagerSource = thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("../VoiceInk/Pinning/PinnedDestinationManager.swift")
            .standardizedFileURL
        let contents = try String(contentsOf: pinnedDestinationManagerSource, encoding: .utf8)
        #expect(!contents.contains("MeetingChunkTextSanitizer"))
    }
}
