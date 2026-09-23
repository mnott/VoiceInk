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

    /// Assigns `speakerID` to every turn whose `diarizedSlot` the library can now put a name (or at
    /// least a stable id) to. Turns with `diarizedSlot == nil` (no diarization, or a slot with no
    /// segment long enough to fingerprint yet) are left as `speakerID == nil` - the generic
    /// "Others" label. `isMe` turns are never touched. A slot where every turn already carries a
    /// `speakerID` (pre-seeded by a caller - see retranscription's "keep speaker ids" carry-forward
    /// in `AudioTranscriptionService`) is left exactly as it is, so calling this repeatedly on
    /// already-identified turns is a no-op rather than re-matching from scratch each time.
    static func assignSpeakers(
        to turns: [MeetingTurnRecord], systemChannel: [Int16], meetingID: UUID, library: SpeakerLibraryStore
    ) async -> [MeetingTurnRecord] {
        let slots = Set(
            turns.filter { !$0.isMe && $0.diarizedSlot != nil && $0.speakerID == nil }.compactMap { $0.diarizedSlot })
        guard !slots.isEmpty else { return turns }

        var idBySlot: [Int: String] = [:]
        for slot in slots {
            let slotTurns = turns.filter { !$0.isMe && $0.diarizedSlot == slot }
            guard let (samples, clip) = enrollmentAudio(for: slotTurns, systemChannel: systemChannel) else { continue }
            guard let embedding = await MeetingSpeakerEmbedder.shared.embedding(for: samples) else { continue }

            if let match = await SpeakerMatching.bestMatch(for: embedding, in: library.voices) {
                await library.recordMatch(id: match.id, embedding: embedding, clipSamples: clip, meetingID: meetingID)
                idBySlot[slot] = match.id
            } else {
                let voice = await library.registerVoice(embedding: embedding, clipSamples: clip, meetingID: meetingID)
                idBySlot[slot] = voice.id
            }
        }

        guard !idBySlot.isEmpty else { return turns }
        return turns.map { turn in
            guard !turn.isMe, let slot = turn.diarizedSlot, let id = idBySlot[slot] else { return turn }
            var updated = turn
            updated.speakerID = id
            return updated
        }
    }

    /// For a meeting whose turns carry no `diarizedSlot` at all (diarization was off, or the model
    /// was unavailable, when it was first transcribed): re-runs offline diarization over the
    /// stored system-channel audio, assigns each existing "Others" turn to whichever diarized
    /// segment its time span overlaps most, then proceeds exactly as `assignSpeakers`. Turns that
    /// already have a `diarizedSlot` are left untouched - this only fills in the gap for the
    /// undiarized ones, so it is safe to call unconditionally from "Identify Speakers".
    static func rediarizeAndAssignSpeakers(
        turns: [MeetingTurnRecord], systemChannel: [Int16], meetingID: UUID, library: SpeakerLibraryStore
    ) async -> [MeetingTurnRecord] {
        let needsDiarization = turns.contains { !$0.isMe && $0.diarizedSlot == nil }
        guard needsDiarization else { return await assignSpeakers(to: turns, systemChannel: systemChannel, meetingID: meetingID, library: library) }

        guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.offlineConfig) else {
            return await assignSpeakers(to: turns, systemChannel: systemChannel, meetingID: meetingID, library: library)
        }
        diarizer.append(systemChannel)
        diarizer.finish()
        guard let attribution = diarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: systemChannel.count) else {
            return await assignSpeakers(to: turns, systemChannel: systemChannel, meetingID: meetingID, library: library)
        }

        let remapped = turns.map { turn -> MeetingTurnRecord in
            guard !turn.isMe, turn.diarizedSlot == nil else { return turn }
            guard let slot = bestOverlappingSlot(start: turn.start, end: turn.end, regions: attribution.regions) else {
                return turn
            }
            var updated = turn
            updated.diarizedSlot = slot
            return updated
        }
        return await assignSpeakers(to: remapped, systemChannel: systemChannel, meetingID: meetingID, library: library)
    }

    /// Seeds `newTurns` with the `speakerID` each diarized slot already had in `previousTurns` -
    /// same underlying audio, same (deterministic) offline diarization, so slot indices are
    /// expected to line up run to run. Used by retranscription so it never re-asks to name a voice
    /// it already knew, without re-running embedding/matching for slots that carried forward
    /// cleanly (see `assignSpeakers`'s no-op guard for already-identified slots).
    static func carryForwardSpeakerIDs(to newTurns: [MeetingTurnRecord], from previousTurns: [MeetingTurnRecord]) -> [MeetingTurnRecord] {
        var idBySlot: [Int: String] = [:]
        for turn in previousTurns where !turn.isMe {
            if let slot = turn.diarizedSlot, let id = turn.speakerID, idBySlot[slot] == nil {
                idBySlot[slot] = id
            }
        }
        guard !idBySlot.isEmpty else { return newTurns }
        return newTurns.map { turn in
            guard !turn.isMe, let slot = turn.diarizedSlot, let id = idBySlot[slot] else { return turn }
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
    /// `maxClipSamples`) for the speaker library's sample player. `nil` if no turn qualifies.
    private static func enrollmentAudio(
        for turns: [MeetingTurnRecord], systemChannel: [Int16]
    ) -> (enrollment: [Int16], clip: [Int16])? {
        let eligible = turns.filter { $0.end - $0.start >= minSegmentSamples && $0.end <= systemChannel.count }
        guard !eligible.isEmpty else { return nil }

        var enrollment: [Int16] = []
        for turn in eligible {
            guard enrollment.count < maxEnrollmentSamples else { break }
            enrollment.append(contentsOf: systemChannel[turn.start..<turn.end])
        }

        let loudest = eligible.max { rms(systemChannel[$0.start..<$0.end]) < rms(systemChannel[$1.start..<$1.end]) }
        let clip = loudest.map { turn -> [Int16] in
            let end = min(turn.end, turn.start + maxClipSamples)
            return Array(systemChannel[turn.start..<end])
        }
        return (enrollment, clip ?? [])
    }

    private static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }
}
