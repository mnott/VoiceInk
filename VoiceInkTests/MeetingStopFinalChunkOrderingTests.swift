import Foundation
import Testing

@testable import VoiceInk

/// A one-shot async gate a test can hold closed indefinitely (unlike `Task.sleep`, which races
/// against real wall-clock scheduling) so a task's completion order can be controlled deterministically
/// - same pattern as `MeetingLiveSpeakerTrackerTests`'s private `Gate`, duplicated here since that one
/// isn't visible across files.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Regression proof for the ordering `VoiceInkEngine+Meeting.toggleMeetingCapture`'s stop branch
/// relies on: the final live chunk's `meetingChunkTask` (started by `deliverMeetingChunk`, chained so
/// transcriptions stay ordered) renders its text by reading `liveSpeakerTracker.state.label(for:)`
/// while running in the background - it must finish doing so *before* the trackers are reset, or the
/// final chunk falls back to the generic "Others" label even though its slot was already diarized/
/// provisionally identified. `MeetingLiveSpeakerTracker` and a `Task` var are exercised directly here,
/// mirroring the exact task-then-reset sequence `toggleMeetingCapture` runs, since driving the full
/// `@MainActor` engine end to end would require real audio hardware and real paste delivery this
/// suite must not touch.
@MainActor
struct MeetingStopFinalChunkOrderingTests {
    @Test func awaitingTheFinalChunkTaskBeforeResettingKeepsItsSlotLabel() async {
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-1a44" }
        tracker.recordTurn(.remote(slot: 1))

        let renderGate = Gate()
        var renderedLabel: String?
        // Mirrors `deliverMeetingChunk`: an unawaited `Task` assigned to a var (standing in for
        // `meetingChunkTask`) that renders the chunk's text - reading tracker labels - only once its
        // (here, gated) transcription work completes.
        let meetingChunkTask = Task {
            await renderGate.wait()
            renderedLabel = tracker.state.label(for: .remote(slot: 1))
        }

        // The fix: `toggleMeetingCapture` now awaits `meetingChunkTask` before resetting.
        await renderGate.open()
        await meetingChunkTask.value
        tracker.reset()

        #expect(renderedLabel == "spk-1a44")
    }

    @Test func resettingBeforeTheFinalChunkTaskFinishesLosesItsSlotLabel() async {
        // The bug this fixes: with the old ordering (reset run right after enqueueing the task,
        // not after awaiting it), the final chunk renders after the tracker is already wiped and
        // falls back to "Others" even though the slot was known.
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-1a44" }
        tracker.recordTurn(.remote(slot: 1))

        let renderGate = Gate()
        var renderedLabel: String?
        let meetingChunkTask = Task {
            await renderGate.wait()
            renderedLabel = tracker.state.label(for: .remote(slot: 1))
        }

        tracker.reset()
        await renderGate.open()
        await meetingChunkTask.value

        #expect(renderedLabel == "Others")
    }

    @Test func aFollowingSessionsFirstChunkNeverReusesTheOldSessionsProvisionalID() async {
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-old" }
        tracker.recordTurn(.remote(slot: 1))
        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-old")

        // Stop: the final chunk's task is awaited (as the fix requires), then the tracker resets.
        await Task { }.value
        tracker.reset()

        // New session, same slot index - must get a fresh id, not the previous session's.
        tracker.generateProvisionalID = { _ in "spk-new" }
        tracker.recordTurn(.remote(slot: 1))
        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-new")
    }

    @Test func sessionIDBySlotSnapshottedAfterTheFinalChunkTaskIncludesItsOwnMatch() async {
        // The fix: `toggleMeetingCapture` now reads `sessionIDBySlot` *after* awaiting
        // `meetingChunkTask`, so a slot first matched/registered by the final chunk's own render
        // step (mirrored here by `recordTurn` running inside the gated task) makes it into the
        // note's id mapping.
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-final" }

        let renderGate = Gate()
        let meetingChunkTask = Task {
            await renderGate.wait()
            tracker.recordTurn(.remote(slot: 2))
        }

        await renderGate.open()
        await meetingChunkTask.value
        let sessionIDBySlot = tracker.state.sessionIDBySlot

        #expect(sessionIDBySlot[2] == "spk-final")
    }

    @Test func sessionIDBySlotSnapshottedBeforeTheFinalChunkTaskMissesItsMatch() async {
        // The bug this fixes: snapshotting before the await (the old ordering) misses whatever the
        // final chunk itself goes on to match/register.
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-final" }

        let renderGate = Gate()
        let meetingChunkTask = Task {
            await renderGate.wait()
            tracker.recordTurn(.remote(slot: 2))
        }

        let sessionIDBySlot = tracker.state.sessionIDBySlot
        await renderGate.open()
        await meetingChunkTask.value

        #expect(sessionIDBySlot[2] == nil)
    }

    @Test func aNewSessionStartedDuringTheFinalChunkWaitIsNotResetByTheOldStop() async {
        // Historical proof for a generation-counter guard `toggleMeetingCapture` no longer needs:
        // `isMeetingCaptureStopping` (see `toggleIgnoredWhileStoppingThenAllowsANewSessionAfterward`
        // below) now blocks a second session from starting at all while the first is stopping, so
        // this "new session started mid-wait" scenario can no longer happen in production. Kept as
        // a demonstration that *if* it did, snapshot-then-compare would be the correct guard.
        var generation = 0
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-old" }
        tracker.recordTurn(.remote(slot: 1))

        let stoppingGeneration = generation
        let renderGate = Gate()
        let meetingChunkTask = Task { await renderGate.wait() }

        // A second hotkey press starts a new session while the old stop's final chunk is still
        // rendering: bumps the generation, resets the tracker itself, and records its own turn.
        generation += 1
        tracker.reset()
        tracker.generateProvisionalID = { _ in "spk-new" }
        tracker.recordTurn(.remote(slot: 1))

        await renderGate.open()
        await meetingChunkTask.value
        if generation == stoppingGeneration {
            tracker.reset()
        }

        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-new")
    }

    @Test func anUnconditionalResetOnStopWipesTheNewSessionStartedDuringTheWait() async {
        // The bug this fixes: resetting unconditionally once the final chunk task finishes (the old
        // ordering) wipes out a new session's already-recorded turn if one started in the meantime.
        // In production this scenario is now prevented one layer up, by `isMeetingCaptureStopping`
        // refusing to let a new session start at all until the old stop returns.
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-old" }
        tracker.recordTurn(.remote(slot: 1))

        let renderGate = Gate()
        let meetingChunkTask = Task { await renderGate.wait() }

        tracker.reset()
        tracker.generateProvisionalID = { _ in "spk-new" }
        tracker.recordTurn(.remote(slot: 1))

        await renderGate.open()
        await meetingChunkTask.value
        tracker.reset()

        #expect(tracker.state.label(for: .remote(slot: 1)) == "Others")
    }

    /// Regression proof for `toggleMeetingCapture`'s `isMeetingCaptureStopping` guard: mirrors its
    /// exact shape (early-return while set, `defer`-cleared at the end of the stop branch) with a
    /// local flag standing in for the `@MainActor` engine property, since driving the real engine
    /// end to end would require real audio hardware - see this file's header doc comment.
    @Test func toggleIgnoredWhileStoppingThenAllowsANewSessionAfterward() async {
        var isStopping = false
        var isActive = true
        var sessionStarts = 0
        var ignoredWhileStopping = 0

        func toggle() async {
            guard !isStopping else {
                ignoredWhileStopping += 1
                return
            }
            if isActive {
                isStopping = true
                defer { isStopping = false }
                await Task.yield()  // stands in for the stop branch's awaits (cut/meetingChunkTask)
                isActive = false
            } else {
                sessionStarts += 1
                isActive = true
            }
        }

        // A stop begins but hasn't finished (its `await` hasn't resumed yet): a second toggle
        // pressed now must be ignored, not start a new session.
        let stopTask = Task { await toggle() }
        await Task.yield()
        await toggle()
        await stopTask.value

        #expect(ignoredWhileStopping == 1)
        #expect(sessionStarts == 0)
        #expect(isActive == false)

        // Once the stop has fully returned, a following toggle starts a new session normally.
        await toggle()
        #expect(sessionStarts == 1)
        #expect(isActive == true)
    }

    /// Regression proof for `pendingAutoSendTask`: an automatic cut already in flight (its
    /// diarizer-commit wait not yet resolved) must finish - and deliver - before the stop branch
    /// performs its own final cut, or the two `cut()` calls on the same capture race each other and
    /// the auto chunk's delivery can land after the final chunk's instead of before it (the live bug
    /// this fixes - see `VoiceInkEngine+Meeting.toggleMeetingCapture`'s stop branch). Models
    /// `pendingAutoSendTask`/the stop branch's capture-clear-await of it directly, mirroring this
    /// file's other tests, since driving the real engine/capture would require real audio hardware.
    @Test func inFlightAutoCutIsAwaitedBeforeStopsFinalCutRuns() async {
        let diarizerCommitGate = Gate()
        var deliveryOrder: [String] = []

        // Mirrors `beginAutoSendChunk`: stored synchronously by the trigger, no await in between.
        let autoCutTask = Task {
            await diarizerCommitGate.wait()
            deliveryOrder.append("auto")
        }
        var pendingAutoSendTask: Task<Void, Never>? = autoCutTask

        // Mirrors the stop branch: captures/clears the pending task and awaits it before running
        // its own final cut - the fix.
        let stopTask = Task {
            let pendingAutoSend = pendingAutoSendTask
            pendingAutoSendTask = nil
            await pendingAutoSend?.value
            deliveryOrder.append("final")
        }

        // Give the stop branch a chance to reach (and block on) its await before the auto cut's
        // own diarizer wait resolves, so the assertion below proves the ordering rather than just
        // accidental scheduling luck.
        await Task.yield()
        await diarizerCommitGate.open()
        await stopTask.value

        #expect(deliveryOrder == ["auto", "final"])
    }

    /// Regression proof for routing manual sends through `pendingCutTask` too (not just automatic
    /// ones): an in-flight manual cut (its `cutForManualSend()` delay/diarizer-commit wait not yet
    /// resolved) must finish - and deliver - before the stop branch performs its own final cut, or
    /// the manual chunk loses diarization and lands after the final chunk instead of before it -
    /// see `VoiceInkEngine+Meeting.sendMeetingChunk`'s doc comment. Same shape as
    /// `inFlightAutoCutIsAwaitedBeforeStopsFinalCutRuns`, with "manual" standing in for "auto".
    @Test func inFlightManualCutIsAwaitedBeforeStopsFinalCutRuns() async {
        let cutDelayGate = Gate()
        var deliveryOrder: [String] = []

        // Mirrors `sendMeetingChunk`: stored synchronously via `beginCutTask`, no await in between.
        let manualCutTask = Task {
            await cutDelayGate.wait()
            deliveryOrder.append("manual")
        }
        var pendingCutTask: Task<Void, Never>? = manualCutTask

        // Mirrors the stop branch: captures/clears the pending task and awaits it before running
        // its own final cut - the fix.
        let stopTask = Task {
            let pendingCut = pendingCutTask
            pendingCutTask = nil
            await pendingCut?.value
            deliveryOrder.append("final")
        }

        // Give the stop branch a chance to reach (and block on) its await before the manual cut's
        // own delay resolves, so the assertion below proves the ordering rather than just
        // accidental scheduling luck.
        await Task.yield()
        await cutDelayGate.open()
        await stopTask.value

        #expect(deliveryOrder == ["manual", "final"])
    }

    @Test func stopNotAwaitingAnInFlightAutoCutLetsTheFinalCutRunFirst() async {
        // The bug this fixes: without capturing/awaiting the pending auto-send task, the stop
        // branch's final cut is free to run - and deliver - before the still-in-flight auto cut,
        // which is exactly the out-of-order/mislabelled-last-passage bug this fix targets.
        let diarizerCommitGate = Gate()
        var deliveryOrder: [String] = []

        let autoCutTask = Task {
            await diarizerCommitGate.wait()
            deliveryOrder.append("auto")
        }

        let stopTask = Task {
            deliveryOrder.append("final")
        }

        await stopTask.value
        await diarizerCommitGate.open()
        await autoCutTask.value

        #expect(deliveryOrder == ["final", "auto"])
    }

    /// Regression proof for `observeLiveSpeakers`'s guard: the stop branch clears
    /// `isMeetingCaptureActive` *before* delivering the final chunk, so that chunk must still be
    /// observed while `isMeetingCaptureStopping` is `true`, or it renders with the "Others"
    /// fallback - see `VoiceInkEngine.shouldObserveLiveSpeakers`'s doc comment.
    @Test func shouldObserveLiveSpeakersDuringTheStoppingSessionsFinalChunk() {
        #expect(VoiceInkEngine.shouldObserveLiveSpeakers(active: false, stopping: true) == true)
        #expect(VoiceInkEngine.shouldObserveLiveSpeakers(active: true, stopping: false) == true)
        #expect(VoiceInkEngine.shouldObserveLiveSpeakers(active: false, stopping: false) == false)
    }
}
