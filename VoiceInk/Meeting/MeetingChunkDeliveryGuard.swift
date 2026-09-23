import Foundation

/// Decides whether a meeting-chunk delivery should be held because the user appears to be
/// actively typing into the pinned (or unpinned cursor-paste) destination right now, so a chunk
/// never lands appended to their half-typed line. See `MeetingChunkDeliveryCoordinator` for the
/// stateful hold loop and merge queue built on top of this. Pure and stateless so the hold/deliver
/// boundary is unit-testable without CGEventSource, AX, or a running capture.
enum MeetingChunkDeliveryGuard {
    /// A chunk is held while a keyDown happened this recently - long enough to cover the pause
    /// between keystrokes in a sentence, short enough that a chunk isn't held indefinitely by
    /// someone who has merely finished typing and moved on to reading.
    static let typingIdleThresholdSeconds: TimeInterval = 3

    /// A keyDown within this long of a chunk/meeting-capture hotkey press is treated as the
    /// hotkey's own keystroke, not the user typing elsewhere - see `shouldHold`'s doc comment.
    static let hotkeyEchoWindowSeconds: TimeInterval = 0.3

    /// Which delivery mechanism the current destination uses, and therefore whether typing has to
    /// land IN that destination to interfere, or ANYWHERE:
    /// - `.iTermSession`: addressed by session id via AppleScript regardless of what's frontmost,
    ///   so only typing while iTerm2 itself is frontmost can interleave with it.
    /// - `.keyboardDriven`: an AX value write, AX keystroke injection, or the unpinned
    ///   cursor-paste fallback - all three go through the keyboard/focus, so any recent typing
    ///   anywhere can land the chunk mid-keystroke.
    enum TargetKind: Equatable {
        case iTermSession
        case keyboardDriven
    }

    /// - Parameters:
    ///   - secondsSinceLastKeyDown: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .keyDown)`,
    ///     read at decision time - see `MeetingChunkDeliveryCoordinator`.
    ///   - now: When this decision is being made.
    ///   - frontmostBundleID: `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`.
    ///   - targetKind: See `TargetKind`.
    ///   - lastHotkeyPressTime: When VoiceInk's own meeting-chunk/meeting-capture hotkey was last
    ///     pressed, if ever - excluded from counting as typing (see below).
    static func shouldHold(
        secondsSinceLastKeyDown: TimeInterval,
        now: Date,
        frontmostBundleID: String?,
        targetKind: TargetKind,
        lastHotkeyPressTime: Date?
    ) -> Bool {
        guard secondsSinceLastKeyDown < typingIdleThresholdSeconds else { return false }

        // The hotkey chord that triggers a manual chunk (or ends a meeting, forcing a final one)
        // is itself a real, physical keyDown, indistinguishable from any other by CGEventSource -
        // without this it would read as "the user is typing" on every single manual/stop-triggered
        // chunk. Reconstructing the last keyDown's timestamp from `secondsSinceLastKeyDown` and
        // comparing it to the recorded hotkey-press time (rather than, say, comparing
        // `secondsSinceLastKeyDown` to `secondsSinceHotkeyPress` directly) is robust to the two
        // being read a few milliseconds apart, since both derive the same absolute instant.
        let lastKeyDownTime = now.addingTimeInterval(-secondsSinceLastKeyDown)
        if let lastHotkeyPressTime,
            abs(lastKeyDownTime.timeIntervalSince(lastHotkeyPressTime)) < hotkeyEchoWindowSeconds
        {
            return false
        }

        switch targetKind {
        case .iTermSession:
            return frontmostBundleID == PinnedTarget.iTermBundleIdentifier
        case .keyboardDriven:
            return true
        }
    }

    /// Maps the current pinned destination (or its absence, i.e. the unpinned cursor-paste
    /// fallback) to which typing scope applies - see `TargetKind`.
    static func targetKind(for pinnedTarget: PinnedTarget?) -> TargetKind {
        guard let pinnedTarget else { return .keyboardDriven }
        switch pinnedTarget {
        case .iTermSession: return .iTermSession
        case .axElement, .axKeystrokeElement: return .keyboardDriven
        }
    }
}

/// Merges meeting-chunk deliveries held back by `MeetingChunkDeliveryGuard` so none is ever
/// dropped: everything queued while delivery is held goes out as one delivery, in arrival order.
/// Pure value type - the stateful hold loop lives in `MeetingChunkDeliveryCoordinator`.
struct MeetingPendingChunkQueue<Payload> {
    struct Entry {
        let text: String
        let payload: Payload
    }
    struct Merged {
        /// Turn-ordered concatenation of every queued chunk's text. Simple newline join rather
        /// than re-merging through `MeetingTurnTranscriptRenderer`: by the time a chunk reaches
        /// this queue it is already rendered speaker-labelled text, not raw turns.
        let text: String
        /// The most recent chunk's payload (e.g. its scratch audio file) - the only one still
        /// needed once the texts are merged into a single delivery.
        let payload: Payload
        /// Every other queued chunk's payload, superseded by the merge and safe to discard.
        let stalePayloads: [Payload]
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func append(text: String, payload: Payload) {
        entries.append(Entry(text: text, payload: payload))
    }

    var merged: Merged? {
        guard let last = entries.last else { return nil }
        let text = entries.map(\.text).joined(separator: "\n\n")
        let stalePayloads = entries.dropLast().map(\.payload)
        return Merged(text: text, payload: last.payload, stalePayloads: stalePayloads)
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
