import Foundation
import Testing

@testable import VoiceInk

// MARK: - "Most recent remote speaker" selection (Name Speaker hotkey target)

struct MostRecentRemoteSpeakerTests {
    @Test func noTurnsYetHasNoMostRecentRemoteSpeaker() {
        let state = MeetingLiveSpeakerState()
        #expect(state.mostRecentRemoteSlot == nil)
        #expect(state.currentSpeaker == nil)
    }

    @Test func singleRemoteTurnIsMostRecent() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        #expect(state.mostRecentRemoteSlot == 1)
    }

    @Test func laterRemoteTurnOverridesAnEarlierOne() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.recordTurn(.remote(slot: 2))
        #expect(state.mostRecentRemoteSlot == 2)
        #expect(state.currentSpeaker == .remote(slot: 2))
    }

    @Test func meSpeakingMostRecentlyDoesNotChangeTheMostRecentRemoteSpeaker() {
        // "Me" turns update `currentSpeaker` (for the live indicator) but the Name Speaker hotkey
        // still needs the last *remote* speaker, since naming "Me" makes no sense.
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.recordTurn(.me)
        #expect(state.currentSpeaker == .me)
        #expect(state.mostRecentRemoteSlot == 1)
    }

    @Test func aSpeakerTakingAnotherTurnMovesToTheEndOfRecency() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.recordTurn(.remote(slot: 2))
        state.recordTurn(.remote(slot: 1))
        #expect(state.mostRecentRemoteSlot == 1)
    }
}

// MARK: - Provisional ids: assigned once per slot, adopted by a fresh library registration

struct ProvisionalIDTests {
    @Test func aSlotWithNoProvisionalOrLibraryIDFallsBackToTheGenericOthersLabel() {
        // Defensive only - the tracker always assigns a provisional id before recording a turn
        // (see `LiveSpeakerMatchStateTests`); the pure state alone makes no such guarantee.
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        #expect(state.label(for: .remote(slot: 1)) == "Others")
        #expect(state.sessionIDBySlot.isEmpty)
    }

    @Test func ensuringAProvisionalIDMakesItTheSlotsLabelAndSessionID() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 3))
        state.ensureProvisionalID(slot: 3, id: "spk-abcd")
        #expect(state.label(for: .remote(slot: 3)) == "spk-abcd")
        #expect(state.sessionIDBySlot == [3: "spk-abcd"])
    }

    @Test func ensuringAProvisionalIDTwiceKeepsTheFirstOne() {
        var state = MeetingLiveSpeakerState()
        state.ensureProvisionalID(slot: 1, id: "spk-first")
        state.ensureProvisionalID(slot: 1, id: "spk-second")
        #expect(state.provisionalID(forSlot: 1) == "spk-first")
    }

    @Test func aLibraryMatchWinsOverTheProvisionalIDInLabelAndSessionID() {
        var state = MeetingLiveSpeakerState()
        state.ensureProvisionalID(slot: 1, id: "spk-provisional")
        state.applyMatch(slot: 1, libraryID: "spk-matched", name: nil)
        #expect(state.label(for: .remote(slot: 1)) == "spk-matched")
        #expect(state.sessionIDBySlot == [1: "spk-matched"])
    }

    @Test func aNameWinsOverBothTheLibraryIDAndTheProvisionalID() {
        var state = MeetingLiveSpeakerState()
        state.ensureProvisionalID(slot: 1, id: "spk-provisional")
        state.applyMatch(slot: 1, libraryID: "spk-matched", name: "Anna")
        #expect(state.label(for: .remote(slot: 1)) == "Anna")
    }

    @Test func reservedIDsThisSessionCoversBothProvisionalAndLibraryIDs() {
        var state = MeetingLiveSpeakerState()
        state.ensureProvisionalID(slot: 1, id: "spk-provisional")
        state.applyMatch(slot: 2, libraryID: "spk-matched", name: nil)
        #expect(state.reservedIDsThisSession == ["spk-provisional", "spk-matched"])
    }
}

// MARK: - Renaming relabels earlier turns, both live and in the persisted meeting note

struct LiveSpeakerRelabelingTests {
    @Test func renamingASlotChangesItsLabelForEveryFutureLookup() {
        // The live state never bakes an old label into anything - `label(for:)` always resolves
        // from the current map, so a rename is retroactive by construction (see
        // `MeetingLiveSpeakerState`'s doc comment).
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.ensureProvisionalID(slot: 1, id: "spk-0001")
        #expect(state.label(for: .remote(slot: 1)) == "spk-0001")

        state.rename(slot: 1, name: "Anna", libraryID: "spk-anna")
        #expect(state.label(for: .remote(slot: 1)) == "Anna")
        #expect(state.libraryID(forSlot: 1) == "spk-anna")
    }

    @Test func renamingOneSlotDoesNotAffectAnother() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.recordTurn(.remote(slot: 2))
        state.ensureProvisionalID(slot: 2, id: "spk-0002")
        state.rename(slot: 1, name: "Anna", libraryID: "spk-anna")
        #expect(state.label(for: .remote(slot: 2)) == "spk-0002")
    }

    @Test func meetingNoteConstructionRelabelsBothEarlierAndLaterTurnsOfTheSameSpeaker() {
        // The whole-meeting note's equivalent of the live state's retroactive rename: turns store
        // a stable `speakerID`, and `render` resolves the label fresh from `nameForSpeakerID` every
        // time, so an "earlier" turn (built before the speaker was ever named) renders with the
        // name exactly like a "later" one once the id is matched to it - no turn is ever rewritten.
        let earlierTurn = MeetingTurnRecord(
            isMe: false, diarizedSlot: 0, speakerID: "spk-abcd", start: 0, end: 100, text: "earlier")
        let laterTurn = MeetingTurnRecord(
            isMe: false, diarizedSlot: 0, speakerID: "spk-abcd", start: 1000, end: 1100, text: "later")

        let beforeNaming = MeetingSpeakerTranscriptRenderer.render([earlierTurn, laterTurn], nameForSpeakerID: { _ in nil })
        #expect(beforeNaming.contains("[spk-abcd:] earlier later"))

        let afterNaming = MeetingSpeakerTranscriptRenderer.render(
            [earlierTurn, laterTurn], nameForSpeakerID: { $0 == "spk-abcd" ? "Anna" : nil })
        #expect(afterNaming.contains("[Anna:] earlier later"))
    }
}

// MARK: - The note's id for a slot must match whatever the live session already showed for it

struct LiveSessionIDBySlotTests {
    @Test func anUnresolvedSlotWithNoProvisionalIDYetIsExcluded() {
        // Defensive only - see `ProvisionalIDTests.aSlotWithNoProvisionalOrLibraryIDFallsBackToTheGenericOthersLabel`.
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 3))
        #expect(state.sessionIDBySlot.isEmpty)
    }

    @Test func aLiveLibraryMatchWinsOverTheProvisionalID() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 1))
        state.ensureProvisionalID(slot: 1, id: "spk-0001")
        state.applyMatch(slot: 1, libraryID: "spk-matched", name: nil)
        #expect(state.sessionIDBySlot == [1: "spk-matched"])
    }

    @Test func aNameSpeakerRenameIsCarriedForwardAsTheSlotsID() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 2))
        state.rename(slot: 2, name: "Anna", libraryID: "spk-anna")
        #expect(state.sessionIDBySlot == [2: "spk-anna"])
    }

    @Test func everySlotHeardThisSessionIsIncluded() {
        var state = MeetingLiveSpeakerState()
        state.recordTurn(.remote(slot: 0))
        state.ensureProvisionalID(slot: 0, id: "spk-0000")
        state.recordTurn(.me)
        state.recordTurn(.remote(slot: 1))
        state.ensureProvisionalID(slot: 1, id: "spk-0001")
        #expect(state.sessionIDBySlot == [0: "spk-0000", 1: "spk-0001"])
    }
}

// MARK: - Live match state transitions (unmatched provisional id -> matched library name)

@MainActor
struct LiveSpeakerMatchStateTests {
    private func makeSamples(count: Int) -> [Int16] { [Int16](repeating: 100, count: count) }
    private static let thresholdSamples = Int(MeetingLiveSpeakerTracker.enrollmentThresholdSeconds * 16_000)

    private func makeTracker(provisionalID: String = "spk-0001") -> MeetingLiveSpeakerTracker {
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in provisionalID }
        return tracker
    }

    @Test func recordingATurnAssignsAFreshRemoteSlotItsProvisionalID() {
        let tracker = makeTracker(provisionalID: "spk-fresh")
        tracker.recordTurn(.remote(slot: 3))
        #expect(tracker.state.label(for: .remote(slot: 3)) == "spk-fresh")
        #expect(tracker.state.provisionalID(forSlot: 3) == "spk-fresh")
        #expect(tracker.state.libraryID(forSlot: 3) == nil)
    }

    @Test func aSecondTurnOnTheSameSlotNeverRegeneratesItsProvisionalID() {
        var callCount = 0
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in
            callCount += 1
            return "spk-\(callCount)"
        }
        tracker.recordTurn(.remote(slot: 1))
        tracker.recordTurn(.remote(slot: 1))
        #expect(callCount == 1)
        #expect(tracker.state.provisionalID(forSlot: 1) == "spk-1")
    }

    @Test func underThresholdAudioNeverTriggersAMatchAttempt() async {
        let tracker = makeTracker()
        var matchAttempted = false
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { _, _, _ in
            matchAttempted = true
            return (id: "spk-mock", name: "Anna")
        }

        let task = tracker.observe(
            slot: 1, samples: makeSamples(count: Self.thresholdSamples - 1)[...], meetingID: UUID())
        #expect(task == nil)
        #expect(matchAttempted == false)
        #expect(tracker.state.libraryID(forSlot: 1) == nil)
    }

    @Test func reachingTheThresholdMatchesAgainstTheInjectedLibraryAndUpdatesTheLiveLabel() async {
        let tracker = makeTracker()
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { embedding, _, _ in
            #expect(embedding == [1, 0, 0])
            return (id: "spk-anna", name: "Anna")
        }

        // Unmatched before enough audio has accumulated - still shows the provisional id.
        tracker.recordTurn(.remote(slot: 1))
        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-0001")

        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        #expect(task != nil)
        await task?.value

        // Matched: the provisional id is replaced by the library name.
        #expect(tracker.state.label(for: .remote(slot: 1)) == "Anna")
        #expect(tracker.state.libraryID(forSlot: 1) == "spk-anna")
        #expect(tracker.pendingMatchTask(forSlot: 1) == nil)
    }

    @Test func matchingAnUnnamedLibraryVoiceSwitchesTheLiveLabelFromProvisionalToLibraryID() async {
        // A live match against a voice the library has never named yet: the label switches from
        // the provisional id to the (now stable, permanent) library id immediately, even with no
        // name - live chunks, the note and the library must never disagree once matched.
        let tracker = makeTracker()
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { _, _, _ in (id: "spk-new", name: nil) }

        tracker.recordTurn(.remote(slot: 1))
        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-0001")

        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        await task?.value

        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-new")
        #expect(tracker.state.libraryID(forSlot: 1) == "spk-new")
    }

    @Test func aFreshRegistrationAdoptsTheSlotsProvisionalIDAsItsPreferredID() async {
        // The root-cause fix: a brand-new voice registered from a live match must carry the exact
        // id already shown live/in the note for this slot, not a freshly generated one.
        let tracker = makeTracker(provisionalID: "spk-adopt-me")
        tracker.embed = { _ in [1, 0, 0] }
        var receivedPreferredID: String?
        tracker.matchOrRegister = { _, _, preferredID in
            receivedPreferredID = preferredID
            return (id: preferredID ?? "spk-fallback", name: nil)
        }

        tracker.recordTurn(.remote(slot: 1))
        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        await task?.value

        #expect(receivedPreferredID == "spk-adopt-me")
        #expect(tracker.state.libraryID(forSlot: 1) == "spk-adopt-me")
    }

    @Test func aSlotIsOnlyEverMatchedOnce() async {
        let tracker = makeTracker()
        var matchCount = 0
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { _, _, _ in
            matchCount += 1
            return (id: "spk-anna", name: "Anna")
        }

        let first = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        await first?.value
        let second = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())

        #expect(second == nil)
        #expect(matchCount == 1)
    }
}

/// A one-shot async gate a test can hold closed indefinitely (unlike a fixed `Task.sleep`, which
/// races against real wall-clock scheduling and is flaky under a heavily parallel test run) so a
/// bounded-wait test can prove its bound expired *before* a slow matcher could possibly have
/// finished, regardless of how long the bound itself actually takes to fire.
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

// MARK: - Bounded wait for an in-flight match before rendering a chunk

@MainActor
struct BoundedMatchWaitTests {
    private func makeSamples(count: Int) -> [Int16] { [Int16](repeating: 100, count: count) }
    private static let thresholdSamples = Int(MeetingLiveSpeakerTracker.enrollmentThresholdSeconds * 16_000)

    @Test func aMatchThatResolvesWithinTheBoundIsReflectedAfterWaiting() async {
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-provisional" }
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { _, _, _ in (id: "spk-anna", name: "Anna") }

        tracker.recordTurn(.remote(slot: 1))
        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        await MeetingLiveSpeakerTracker.awaitBoundedMatches([task].compactMap { $0 }, timeout: .seconds(5))

        #expect(tracker.state.label(for: .remote(slot: 1)) == "Anna")
    }

    @Test func aMatchStillPendingAfterTheBoundLeavesTheProvisionalIDShowing() async {
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-provisional" }
        let embedGate = Gate()
        tracker.embed = { _ in
            await embedGate.wait()
            return [1, 0, 0]
        }
        tracker.matchOrRegister = { _, _, _ in (id: "spk-anna", name: "Anna") }

        tracker.recordTurn(.remote(slot: 1))
        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())
        // The embed is held closed, so it cannot possibly finish before this returns - proving the
        // bound, not luck, is what stops the wait here, however long the bound itself takes to fire.
        await MeetingLiveSpeakerTracker.awaitBoundedMatches([task].compactMap { $0 }, timeout: .milliseconds(1))

        #expect(tracker.state.label(for: .remote(slot: 1)) == "spk-provisional")

        await embedGate.open()
        await task?.value

        // The match landed afterwards regardless, and is cached for the rest of the session.
        #expect(tracker.state.label(for: .remote(slot: 1)) == "Anna")
    }

    @Test func noPendingTasksReturnsImmediately() async {
        await MeetingLiveSpeakerTracker.awaitBoundedMatches([], timeout: .seconds(10))
    }

    @Test func pendingMatchTaskIsAvailableToACallerThatDidNotStartItThisChunk() async {
        // A match that started in an earlier chunk (per `observe`'s "only ever matched once") is
        // still discoverable by a later chunk that wants to bound-wait it too.
        let tracker = MeetingLiveSpeakerTracker()
        tracker.generateProvisionalID = { _ in "spk-provisional" }
        tracker.embed = { _ in [1, 0, 0] }
        tracker.matchOrRegister = { _, _, _ in (id: "spk-anna", name: "Anna") }

        tracker.recordTurn(.remote(slot: 1))
        let task = tracker.observe(slot: 1, samples: makeSamples(count: Self.thresholdSamples)[...], meetingID: UUID())

        let rediscovered = tracker.pendingMatchTask(forSlot: 1)
        #expect(rediscovered != nil)
        await task?.value
        #expect(tracker.state.label(for: .remote(slot: 1)) == "Anna")
        #expect(tracker.pendingMatchTask(forSlot: 1) == nil)
    }
}
