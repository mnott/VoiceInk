import Foundation

/// Pure, synchronous "who's currently speaking" state for one Meeting Capture session: which
/// speaker (me, or a diarized remote slot) most recently had a turn, and whatever label each
/// remote slot currently carries - its provisional id (`spk-XXXX`, generated the same way a library
/// id is) until a live library match or the "Name Speaker" hotkey resolves it to a name. No I/O, no
/// async - see `MeetingLiveSpeakerTracker` for the embedding/matching work that feeds
/// `applyMatch`/`rename`. Every label lookup reads the current map fresh, so a rename is retroactive
/// for free: nothing here ever bakes an old label into a turn (the same reason
/// `MeetingSpeakerTranscriptRenderer.render` - the persisted-note equivalent - re-labels every past
/// turn on a library rename, not just future ones).
struct MeetingLiveSpeakerState: Equatable {
    enum LiveSpeaker: Equatable, Hashable {
        case me
        case remote(slot: Int)
    }

    private(set) var recencyOrder: [LiveSpeaker] = []
    private(set) var labelBySlot: [Int: String] = [:]
    private(set) var libraryIDBySlot: [Int: String] = [:]
    private(set) var provisionalIDBySlot: [Int: String] = [:]

    /// Called once per turn, in turn order, as chunks are transcribed.
    mutating func recordTurn(_ speaker: LiveSpeaker) {
        recencyOrder.removeAll { $0 == speaker }
        recencyOrder.append(speaker)
    }

    var currentSpeaker: LiveSpeaker? { recencyOrder.last }

    /// The slot the "Name Speaker" hotkey should target - the most recently active remote
    /// (non-"Me") speaker, regardless of whether "Me" has spoken more recently since.
    var mostRecentRemoteSlot: Int? {
        for speaker in recencyOrder.reversed() {
            if case .remote(let slot) = speaker { return slot }
        }
        return nil
    }

    func libraryID(forSlot slot: Int) -> String? { libraryIDBySlot[slot] }
    func provisionalID(forSlot slot: Int) -> String? { provisionalIDBySlot[slot] }

    /// The id a remote slot should carry before any library match exists - assigned once, on its
    /// first turn (see `MeetingLiveSpeakerTracker.recordTurn`), generated the same way a library id
    /// is (`SpeakerMatching.generateID`) and never overwritten: it is exactly the id a newly
    /// registered voice for this slot adopts (`SpeakerLibraryStore.registerVoice`'s `preferredID`),
    /// so live chunks, the note and the library id agree even before a match happens. A no-op once
    /// the slot already has one.
    mutating func ensureProvisionalID(slot: Int, id: String) {
        guard provisionalIDBySlot[slot] == nil else { return }
        provisionalIDBySlot[slot] = id
    }

    /// A live library match found for `slot` - `name` is `nil` when the matched/registered voice
    /// has no name yet, in which case the slot keeps showing its stable id (see `label(for:)`).
    mutating func applyMatch(slot: Int, libraryID: String, name: String?) {
        libraryIDBySlot[slot] = libraryID
        if let name { labelBySlot[slot] = name } else { labelBySlot.removeValue(forKey: slot) }
    }

    /// The "Name Speaker" hotkey: applies immediately to every future `label(for:)` call for this
    /// slot (and, since nothing else here remembers old labels, is exactly as retroactive as the
    /// live state can be - see this type's doc comment).
    mutating func rename(slot: Int, name: String, libraryID: String) {
        labelBySlot[slot] = name
        libraryIDBySlot[slot] = libraryID
    }

    /// Every id this session has already handed a remote slot, provisional or library-matched -
    /// reserved so a freshly generated provisional id for another slot can never collide with one
    /// already in use this session (see `MeetingLiveSpeakerTracker.recordTurn`).
    var reservedIDsThisSession: Set<String> { Set(provisionalIDBySlot.values).union(libraryIDBySlot.values) }

    /// The id/name a remote slot currently resolves to, in precedence order: its library name, else
    /// its library id once matched, else its provisional id.
    private func stableID(forSlot slot: Int) -> String? { libraryIDBySlot[slot] ?? provisionalIDBySlot[slot] }

    func label(for speaker: LiveSpeaker) -> String {
        switch speaker {
        case .me: return String(localized: "Me")
        case .remote(let slot): return labelBySlot[slot] ?? stableID(forSlot: slot) ?? String(localized: "Others")
        }
    }

    /// Every remote slot heard this session, mapped to the id the whole-meeting note should reuse
    /// for it - the slot's live library match (`libraryIDBySlot`) if the embedder resolved one (or
    /// the "Name Speaker" hotkey set one), else its provisional id. Lets
    /// `MeetingSpeakerIdentifier.assignSpeakers` keep a diarized slot's note id identical to what
    /// live chunks already showed for it, instead of re-deriving (and potentially disagreeing on) an
    /// id from scratch when no embedding is available.
    var sessionIDBySlot: [Int: String] {
        var result = libraryIDBySlot
        for case .remote(let slot) in recencyOrder where result[slot] == nil {
            if let provisional = provisionalIDBySlot[slot] { result[slot] = provisional }
        }
        return result
    }
}

/// Drives `MeetingLiveSpeakerState` for one Meeting Capture session: buffers each remote slot's
/// audio until it has >= `enrollmentThresholdSeconds` of speech, then matches it against the
/// speaker library - off the chunk-delivery path (fire-and-forget `Task`, never awaited by the
/// caller) so per-chunk latency doesn't grow, though `awaitBoundedMatches` lets a caller wait a
/// short bounded time for one to land before rendering. `embed`/`matchOrRegister` are the real
/// `MeetingSpeakerEmbedder`/`SpeakerLibraryStore` in production and injectable in tests, so live
/// match-state transitions are verifiable without a downloaded model or real audio.
@MainActor
final class MeetingLiveSpeakerTracker: ObservableObject {
    @Published private(set) var state = MeetingLiveSpeakerState() {
        didSet { onStateChange?() }
    }
    /// Fires on every state change, including the ones `observe`'s background match applies - lets
    /// `VoiceInkEngine` mirror `currentSpeaker`'s label into its own `@Published` property for the
    /// menu bar indicator without every call site here remembering to notify it separately.
    var onStateChange: (() -> Void)?

    static let enrollmentThresholdSeconds: Double = 3
    /// Bound for `awaitBoundedMatches` - a chunk waits at most this long for an in-flight live match
    /// before rendering with the slot's provisional id instead. Embedding is fast, so this is only
    /// ever hit by an unusually slow/stuck matcher, and the match keeps running in the background
    /// regardless (see `awaitBoundedMatches`'s doc comment).
    static let matchWaitTimeout: Duration = .seconds(1)
    private static let sampleRate = 16_000

    private var pendingSamplesBySlot: [Int: [Int16]] = [:]
    private var enrollmentStartedForSlot: Set<Int> = []
    /// The still-running match `Task` for a slot that has crossed the enrollment threshold but has
    /// no library match yet - removed once `applyMatch` resolves it. Lets `awaitBoundedMatches` find
    /// and wait on a match that started in an earlier chunk, not just one `observe` just started.
    private var inFlightMatchBySlot: [Int: Task<Void, Never>] = [:]

    var embed: ([Int16]) async -> [Float]? = { await MeetingSpeakerEmbedder.shared.embedding(for: $0) }
    var matchOrRegister: ([Float], UUID, String?) async -> (id: String, name: String?) = {
        embedding, meetingID, preferredID in
        let library = SpeakerLibraryStore.shared
        if let match = SpeakerMatching.bestMatch(for: embedding, in: library.voices) {
            library.recordMatch(id: match.id, embedding: embedding, clipSamples: nil, meetingID: meetingID)
            return (match.id, library.name(for: match.id))
        }
        let voice = library.registerVoice(
            embedding: embedding, clipSamples: nil, meetingID: meetingID, preferredID: preferredID)
        return (voice.id, voice.name)
    }
    /// Generates a slot's provisional id - overridable in tests for determinism. Production excludes
    /// both the persistent library's ids and every id already handed out this session (see
    /// `MeetingLiveSpeakerState.reservedIDsThisSession`).
    var generateProvisionalID: (Set<String>) -> String = { SpeakerMatching.generateID(excluding: $0) }

    func reset() {
        state = MeetingLiveSpeakerState()
        pendingSamplesBySlot = [:]
        enrollmentStartedForSlot = []
        inFlightMatchBySlot = [:]
    }

    /// Records a turn, first assigning a fresh remote slot its provisional id (see
    /// `MeetingLiveSpeakerState.ensureProvisionalID`) so every label/lookup for it from this call
    /// onward has a stable id to show before any library match exists.
    func recordTurn(_ speaker: MeetingLiveSpeakerState.LiveSpeaker) {
        if case .remote(let slot) = speaker, state.libraryID(forSlot: slot) == nil, state.provisionalID(forSlot: slot) == nil {
            let reserved = Set(SpeakerLibraryStore.shared.voices.map(\.id)).union(state.reservedIDsThisSession)
            state.ensureProvisionalID(slot: slot, id: generateProvisionalID(reserved))
        }
        state.recordTurn(speaker)
    }

    /// Buffers a diarized remote turn's audio for `slot`; once enough has accumulated and no match
    /// attempt has started yet, kicks off embedding + library matching in the background. Returns
    /// the background `Task` (nil when no match attempt started this call) purely so tests can
    /// `await` it deterministically instead of sleeping - production callers never await it directly
    /// (see `awaitBoundedMatches` for the bounded wait they use instead), which is what keeps this
    /// off the chunk-delivery path.
    @discardableResult
    func observe(slot: Int, samples: ArraySlice<Int16>, meetingID: UUID) -> Task<Void, Never>? {
        guard !enrollmentStartedForSlot.contains(slot) else { return nil }
        pendingSamplesBySlot[slot, default: []].append(contentsOf: samples)
        guard Double(pendingSamplesBySlot[slot]!.count) >= Self.enrollmentThresholdSeconds * Double(Self.sampleRate)
        else { return nil }

        enrollmentStartedForSlot.insert(slot)
        let clip = pendingSamplesBySlot.removeValue(forKey: slot) ?? []
        let preferredID = state.libraryID(forSlot: slot) ?? state.provisionalID(forSlot: slot)
        let task = Task { [weak self, embed, matchOrRegister] in
            defer { self?.inFlightMatchBySlot.removeValue(forKey: slot) }
            guard let self, let embedding = await embed(clip) else { return }
            let (id, name) = await matchOrRegister(embedding, meetingID, preferredID)
            self.state.applyMatch(slot: slot, libraryID: id, name: name)
        }
        inFlightMatchBySlot[slot] = task
        return task
    }

    /// The still-running match task for `slot`, if it has crossed the enrollment threshold but has
    /// no library match yet - `nil` once matched, or if it never started. Used by callers (see
    /// `VoiceInkEngine.observeLiveSpeakers`) to bound-wait a match before rendering a chunk that
    /// includes this slot, whether the match started this chunk or an earlier one.
    func pendingMatchTask(forSlot slot: Int) -> Task<Void, Never>? { inFlightMatchBySlot[slot] }

    /// Waits up to `timeout` for `tasks` - each an in-flight live match for a slot about to be
    /// rendered - to finish, then gives up: every match keeps running in the background and is
    /// cached per slot regardless (`observe`/`applyMatch`), so this only ever delays rendering by up
    /// to `timeout`, never blocks on a slow (or stuck) embed indefinitely. Deliberately not
    /// `withTaskGroup`-based: a structured group waits for every cancelled child to actually finish
    /// before returning, so racing the wait itself against `Task.sleep` inside one group would still
    /// block on a match that never completes - two detached, unstructured `Task`s racing to resume a
    /// single continuation avoid that, letting the timed-out loser keep running unobserved.
    static func awaitBoundedMatches(_ tasks: [Task<Void, Never>], timeout: Duration = matchWaitTimeout) async {
        guard !tasks.isEmpty else { return }
        let resumeOnce = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                for task in tasks { await task.value }
                await resumeOnce.resume(continuation)
            }
            Task {
                try? await Task.sleep(for: timeout)
                await resumeOnce.resume(continuation)
            }
        }
    }

    /// Ensures only the first of two racing `Task`s resumes a `CheckedContinuation` - resuming twice
    /// is a fatal error, and both `awaitBoundedMatches` races are expected to race genuinely.
    private actor ResumeOnce {
        private var didResume = false
        func resume(_ continuation: CheckedContinuation<Void, Never>) {
            guard !didResume else { return }
            didResume = true
            continuation.resume()
        }
    }

    /// "Name Speaker" hotkey: names (registering first if the slot never reached the live-match
    /// threshold) or merges `slot`'s voice into an existing library entry called `name`, applying
    /// immediately to the live label. Whatever audio has accumulated for the slot so far (even
    /// under the live-match threshold) enrols/updates the voice's embedding.
    func nameSpeaker(slot: Int, name: String, meetingID: UUID) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let library = SpeakerLibraryStore.shared
        let clip = pendingSamplesBySlot.removeValue(forKey: slot)
        enrollmentStartedForSlot.insert(slot)
        var embedding: [Float]?
        if let clip, !clip.isEmpty {
            embedding = await embed(clip)
        }

        let existingID = state.libraryID(forSlot: slot)
        let targetID: String
        if let matchedExisting = library.voices.first(where: { $0.name?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            if let existingID, existingID != matchedExisting.id {
                library.merge(sourceID: existingID, intoTargetID: matchedExisting.id)
            }
            targetID = matchedExisting.id
        } else if let existingID {
            targetID = existingID
        } else {
            targetID = library.registerVoice(
                embedding: embedding ?? [], clipSamples: nil, meetingID: meetingID,
                preferredID: state.provisionalID(forSlot: slot)
            ).id
        }

        if let embedding {
            library.recordMatch(id: targetID, embedding: embedding, clipSamples: nil, meetingID: meetingID)
        }
        library.rename(id: targetID, to: trimmed)
        state.rename(slot: slot, name: trimmed, libraryID: targetID)
    }
}
