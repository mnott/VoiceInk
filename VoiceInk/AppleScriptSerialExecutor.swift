import Foundation

/// Serializes every `NSAppleScript` execution in the app through one dedicated serial
/// queue. `NSAppleScript` is not thread-safe, and this app runs AppleScript from more
/// than one place - pinned-destination delivery and session lookups
/// (`PinnedDestinationManager`), and the AppleScript paste fallback (`CursorPaster`) -
/// so without a single shared executor those can run concurrently on different
/// threads/tasks. That concurrency is a real, observed source of spurious failures: a
/// live iTerm2 session receiving a transient `-600` ("Application isn't running")
/// while iTerm2 was, in fact, running the entire time, immediately after a prior
/// AppleScript call to the same app had started on another thread.
///
/// Still off the main thread - see the reasoning above `PinnedDestinationManager`'s
/// `runAppleScript`, which this replaces the ad-hoc `Task.detached` in: a slow script
/// (enumerating many iTerm2 panes, say) must never stall the UI. A single serial queue
/// only serializes AppleScript calls against EACH OTHER, not against the main thread.
enum AppleScriptSerialExecutor {
    private static let queue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.applescript", qos: .userInitiated)

    /// Runs `body` on the shared serial queue and returns its result, never overlapping
    /// with any other call made through this executor.
    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }
}
