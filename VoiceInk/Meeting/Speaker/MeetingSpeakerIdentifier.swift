import Foundation

/// Turns a meeting's diarized-but-not-yet-identified turns into identified ones: one embedding per
/// diarized cluster (see `MeetingSpeakerEmbedder`), matched or newly registered against the
/// persistent speaker library (see `SpeakerLibraryStore`/`SpeakerMatching`). Runs both
/// automatically right after a meeting's initial transcription/retranscription (whenever
/// diarization already produced `diarizedSlot`s) and from the History "Identify Speakers" action
/// (which additionally handles meetings that have no slots at all yet - see
/// `rediarizeAndAssignSpeakers`).
enum MeetingSpeakerIdentifier {
    private static let sampleRate = 16000
    private static let minSegmentSamples = Int(1.5 * Double(sampleRate))
    private static let maxEnrollmentSamples = Int(10 * Double(sampleRate))
    private static let maxClipSamples = Int(4 * Double(sampleRate))

    /// Resolves the id one diarized slot's turns should carry: a library match (or a freshly
    /// registered voice) from this pass's embedding wins when there is one; otherwise the slot
    /// keeps the id it already carried live (`sessionID`, from the live speaker tracker or "Name
    /// Speaker" - see `MeetingLiveSpeakerState.sessionIDBySlot`) rather than getting a fresh one,
    /// so live chunks, the note and the library agree. `freshID` (a distinct, never-yet-used
    /// `spk-XXXX`) is the last resort so a diarized slot is never left without a stable id -
    /// collapsing distinct diarized speakers into the generic "Others" label only ever happens for
    /// turns with no diarized slot at all.
    static func resolvedSpeakerID(libraryMatchID: String?, sessionID: String?, freshID: @autoclosure () -> String) -> String {
        libraryMatchID ?? sessionID ?? freshID()
    }

    /// Assigns `speakerID` to every turn whose `diarizedSlot` doesn't have one yet. `sessionIDBySlot`
    /// (see `MeetingLiveSpeakerState.sessionIDBySlot`) carries forward whatever id live chunks of
    /// this same session already showed for a system-channel slot, `micSessionIDBySlot` the same
    /// for mic-channel slots (`micSpeakerTracker`) - each channel's diarizer numbers its slots from
    /// 0 independently, so the channel + slot pair, not the slot alone, identifies a speaker (see
    /// `MeetingTurnRecord.DiarizedKey`). A slot is never given a different id just because the
    /// speaker-embedding model is unavailable at note-writing time (or embedding this slot's clip
    /// failed) - see `resolvedSpeakerID`. `isMe` turns are never touched. A slot where every turn
    /// already carries a `speakerID` (pre-seeded by a caller - see retranscription's "keep speaker
    /// ids" carry-forward in `AudioTranscriptionService`) is left exactly as it is, so calling this
    /// repeatedly on already-identified turns is a no-op rather than re-matching from scratch each
    /// time. A mic-channel slot whose resolved voice is flagged "this is me" turns its turns into
    /// `isMe` ones - the note-path equivalent of `MeetingMicSpeakerMapper`'s live rendering.
    static func assignSpeakers(
        to turns: [MeetingTurnRecord], systemChannel: [Int16], micChannel: [Int16] = [],
        meetingID: UUID, library: SpeakerLibraryStore,
        sessionIDBySlot: [Int: String] = [:], micSessionIDBySlot: [Int: String] = [:],
        embed: ([Int16]) async -> [Float]? = { await MeetingSpeakerEmbedder.shared.embedding(for: $0) }
    ) async -> [MeetingTurnRecord] {
        let slots = Set(turns.filter { !$0.isMe && $0.speakerID == nil }.compactMap(\.diarizedKey))
        guard !slots.isEmpty else { return turns }

        var idByKey: [MeetingTurnRecord.DiarizedKey: String] = [:]
        var meVoiceKeys: Set<MeetingTurnRecord.DiarizedKey> = []
        var reservedIDs = Set(await library.voices.map(\.id))
        for key in slots {
            let slotTurns = turns.filter { !$0.isMe && $0.diarizedKey == key }
            // A slot's audio lives in its own channel; an empty channel (callers that don't have
            // one) simply enrols nothing, falling back to the slot's session/fresh id.
            let channel = key.isMicChannel ? micChannel : systemChannel
            var libraryMatchID: String?
            if let (samples, clip) = enrollmentAudio(for: slotTurns, channel: channel),
                let embedding = await embed(samples)
            {
                if let match = await SpeakerMatching.bestMatch(for: embedding, in: library.voices) {
                    await library.recordMatch(id: match.id, embedding: embedding, clipSamples: clip, meetingID: meetingID)
                    libraryMatchID = match.id
                } else {
                    let preferredID = key.isMicChannel ? micSessionIDBySlot[key.slot] : sessionIDBySlot[key.slot]
                    let voice = await library.registerVoice(
                        embedding: embedding, clipSamples: clip, meetingID: meetingID, preferredID: preferredID)
                    libraryMatchID = voice.id
                }
            }

            let sessionID = key.isMicChannel ? micSessionIDBySlot[key.slot] : sessionIDBySlot[key.slot]
            let id = resolvedSpeakerID(
                libraryMatchID: libraryMatchID, sessionID: sessionID,
                freshID: SpeakerMatching.generateID(excluding: reservedIDs))
            idByKey[key] = id
            reservedIDs.insert(id)
            if key.isMicChannel, await library.voice(for: id)?.isMe == true { meVoiceKeys.insert(key) }
        }

        return turns.map { turn in
            guard !turn.isMe, let key = turn.diarizedKey, let id = idByKey[key] else { return turn }
            var updated = turn
            if meVoiceKeys.contains(key) {
                updated.isMe = true
            } else {
                updated.speakerID = id
            }
            return updated
        }
    }

    /// For a meeting whose turns carry no `diarizedSlot` at all (diarization was off, or the model
    /// was unavailable, when it was first transcribed): re-runs offline diarization over the
    /// stored system-channel audio, assigns each existing "Others" turn to whichever diarized
    /// segment its time span overlaps most, then proceeds exactly as `assignSpeakers`. Turns that
    /// already have a `diarizedSlot` are left untouched - this only fills in the gap for the
    /// undiarized ones, so it is safe to call unconditionally from "Identify Speakers". Mic-channel
    /// turns are also never remapped: the re-diarization runs over the system audio, and the mic
    /// channel's slot space belongs to a different diarizer (see `MeetingTurnRecord.DiarizedKey`).
    static func rediarizeAndAssignSpeakers(
        turns: [MeetingTurnRecord], systemChannel: [Int16], micChannel: [Int16] = [],
        meetingID: UUID, library: SpeakerLibraryStore
    ) async -> [MeetingTurnRecord] {
        let needsDiarization = turns.contains { !$0.isMe && !$0.isMicChannel && $0.diarizedSlot == nil }
        guard needsDiarization else {
            return await assignSpeakers(
                to: turns, systemChannel: systemChannel, micChannel: micChannel, meetingID: meetingID, library: library)
        }

        guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.offlineConfig) else {
            return await assignSpeakers(
                to: turns, systemChannel: systemChannel, micChannel: micChannel, meetingID: meetingID, library: library)
        }
        diarizer.append(systemChannel)
        diarizer.finish()
        let attribution = diarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: systemChannel.count)

        let remapped = turns.map { turn -> MeetingTurnRecord in
            guard !turn.isMe, !turn.isMicChannel, turn.diarizedSlot == nil else { return turn }
            guard let slot = bestOverlappingSlot(start: turn.start, end: turn.end, regions: attribution.regions) else {
                return turn
            }
            var updated = turn
            updated.diarizedSlot = slot
            return updated
        }
        return await assignSpeakers(
            to: remapped, systemChannel: systemChannel, micChannel: micChannel, meetingID: meetingID, library: library)
    }

    /// Seeds `newTurns` with the `speakerID` each diarized slot already had in `previousTurns` -
    /// same underlying audio, same (deterministic) offline diarization, so slot indices are
    /// expected to line up run to run (per channel - see `MeetingTurnRecord.DiarizedKey`). Used by
    /// retranscription so it never re-asks to name a voice it already knew, without re-running
    /// embedding/matching for slots that carried forward cleanly (see `assignSpeakers`'s no-op
    /// guard for already-identified slots).
    static func carryForwardSpeakerIDs(to newTurns: [MeetingTurnRecord], from previousTurns: [MeetingTurnRecord]) -> [MeetingTurnRecord] {
        var idByKey: [MeetingTurnRecord.DiarizedKey: String] = [:]
        for turn in previousTurns where !turn.isMe {
            if let key = turn.diarizedKey, let id = turn.speakerID, idByKey[key] == nil {
                idByKey[key] = id
            }
        }
        guard !idByKey.isEmpty else { return newTurns }
        return newTurns.map { turn in
            guard !turn.isMe, let key = turn.diarizedKey, let id = idByKey[key] else { return turn }
            var updated = turn
            updated.speakerID = id
            return updated
        }
    }

    private static func bestOverlappingSlot(
        start: Int, end: Int, regions: [(speaker: Int, start: Int, end: Int)]
    ) -> Int? {
        var bestSlot: Int?
        var bestOverlap = 0
        for region in regions {
            let overlap = min(end, region.end) - max(start, region.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSlot = region.speaker
            }
        }
        return bestSlot
    }

    /// Concatenates up to `maxEnrollmentSamples` of audio from this slot's turns that are each at
    /// least `minSegmentSamples` long, plus a single clip (the loudest such turn, capped to
    /// `maxClipSamples`) for the speaker library's sample player. `nil` if no turn qualifies or
    /// the slot's channel has no samples.
    private static func enrollmentAudio(
        for turns: [MeetingTurnRecord], channel: [Int16]
    ) -> (enrollment: [Int16], clip: [Int16])? {
        let eligible = turns.filter { $0.end - $0.start >= minSegmentSamples && $0.end <= channel.count }
        guard !eligible.isEmpty else { return nil }

        var enrollment: [Int16] = []
        for turn in eligible {
            guard enrollment.count < maxEnrollmentSamples else { break }
            enrollment.append(contentsOf: channel[turn.start..<turn.end])
        }

        let loudest = eligible.max { rms(channel[$0.start..<$0.end]) < rms(channel[$1.start..<$1.end]) }
        let clip = loudest.map { turn -> [Int16] in
            let end = min(turn.end, turn.start + maxClipSamples)
            return Array(channel[turn.start..<end])
        }
        return (enrollment, clip ?? [])
    }

    private static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }
}
