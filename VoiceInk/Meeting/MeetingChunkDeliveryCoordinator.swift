import AppKit
import CoreGraphics
import Foundation
import os

/// Holds meeting-chunk deliveries while the user is typing into the destination (see
/// `MeetingChunkDeliveryGuard`), merging anything that arrives while held so nothing is ever
/// dropped (`MeetingPendingChunkQueue`). Owns no delivery mechanism itself - `deliver` is supplied
/// by the caller (see `VoiceInkEngine+Meeting`).
///
/// Deliberately NOT part of the `meetingChunkTask` chain that serializes transcription (the local
/// Whisper model isn't safe to run concurrently): a chunk is only handed to this coordinator once
/// its transcription has already finished, so holding a delivery here never blocks the *next*
/// chunk's transcription from starting - only its own delivery.
@MainActor
final class MeetingChunkDeliveryCoordinator<Payload> {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingAudioCapture")

    /// How often a held chunk re-checks whether typing has stopped.
    private static var recheckIntervalSeconds: TimeInterval { 0.5 }

    private var pending = MeetingPendingChunkQueue<Payload>()
    private var holdLoopTask: Task<Void, Never>?

    /// Set by `RecordingShortcutManager` whenever the meeting-chunk or meeting-capture hotkey is
    /// pressed - see `MeetingChunkDeliveryGuard.shouldHold`'s hotkey-echo exclusion.
    var lastHotkeyPressTime: Date?

    private let deliver: (String, Payload) async -> Void
    private let discard: (Payload) -> Void

    /// - Parameters:
    ///   - deliver: Called with the (possibly merged) text and the payload to deliver it with.
    ///   - discard: Called for a payload that was merged away (e.g. to delete its now-unused
    ///     scratch audio file) - never called for the payload passed to `deliver`.
    init(deliver: @escaping (String, Payload) async -> Void, discard: @escaping (Payload) -> Void) {
        self.deliver = deliver
        self.discard = discard
    }

    /// Submits one chunk's already-transcribed, already-rendered text for delivery: delivered
    /// immediately if the user isn't typing into the destination right now, held (and merged with
    /// anything else that arrives) otherwise.
    func submit(text: String, payload: Payload) {
        guard !text.isEmpty else {
            discard(payload)
            return
        }

        guard holdLoopTask == nil else {
            // A hold loop is already running - it will pick this up on its own next re-check.
            pending.append(text: text, payload: payload)
            return
        }

        guard Self.currentlyShouldHold(lastHotkeyPressTime: lastHotkeyPressTime) else {
            Task { await self.deliver(text, payload) }
            return
        }

        pending.append(text: text, payload: payload)
        startHoldLoop()
    }

    private func startHoldLoop() {
        logger.info("Meeting chunk delivery held: user appears to be typing into the destination.")
        holdLoopTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: UInt64(Self.recheckIntervalSeconds * 1_000_000_000))
                guard !Self.currentlyShouldHold(lastHotkeyPressTime: self.lastHotkeyPressTime) else { continue }
                break
            }
            guard let self else { return }
            self.holdLoopTask = nil
            guard let merged = self.pending.merged else { return }
            self.pending.removeAll()
            for stale in merged.stalePayloads { self.discard(stale) }
            self.logger.info("Meeting chunk delivery released.")
            await self.deliver(merged.text, merged.payload)
        }
    }

    private static func currentlyShouldHold(lastHotkeyPressTime: Date?) -> Bool {
        // `.combinedSessionState` needs no event tap and no Input Monitoring permission - it
        // reads a system-maintained "seconds since" counter, verified working from an
        // unentitled process.
        let secondsSinceLastKeyDown = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown)
        let targetKind = MeetingChunkDeliveryGuard.targetKind(for: PinnedDestinationManager.shared.pinned)
        return MeetingChunkDeliveryGuard.shouldHold(
            secondsSinceLastKeyDown: secondsSinceLastKeyDown,
            now: Date(),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            targetKind: targetKind,
            lastHotkeyPressTime: lastHotkeyPressTime)
    }
}
