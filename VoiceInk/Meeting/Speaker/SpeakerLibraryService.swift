import Foundation
import SwiftData

/// Speaker-library actions that must also touch every meeting History record - renaming, merging,
/// and deleting a voice all change what `text` should render as, everywhere that voice appears
/// (see `Notes/speaker-library-spec.md`: "Naming a voice later updates every past transcript").
/// `SpeakerLibraryStore` itself only knows about the library file; this is the thin layer that adds
/// the SwiftData side.
@MainActor
enum SpeakerLibraryService {
    static func rename(id: String, to name: String?, library: SpeakerLibraryStore, modelContext: ModelContext) {
        library.rename(id: id, to: name)
        rerenderMeetings(referencing: [id], library: library, modelContext: modelContext)
    }

    /// What (if anything) a rename UI should persist once it reaches a commit point (Return
    /// pressed, or focus lost) - `nil` when `draft` doesn't actually differ from what's already
    /// stored. Exists so a rename field can gate `rename` (which re-renders every meeting that
    /// references the voice) behind an explicit commit rather than firing it on every keystroke:
    /// a field left focused after a previous rename used to stay armed to silently overwrite the
    /// name with whatever stray text next reached it (e.g. dictation typed at the cursor
    /// elsewhere), since each keystroke was persisted as soon as it landed. `nonisolated` so this
    /// pure comparison is unit-testable without any view or store state.
    nonisolated static func valueToPersist(draft: String, currentName: String?) -> String? {
        draft == (currentName ?? "") ? nil : draft
    }

    /// Merges `sourceID` into `targetID` and remaps every meeting record's turns accordingly.
    static func merge(sourceID: String, intoTargetID targetID: String, library: SpeakerLibraryStore, modelContext: ModelContext) {
        guard sourceID != targetID else { return }
        library.merge(sourceID: sourceID, intoTargetID: targetID)

        for transcription in meetingRecordings(modelContext: modelContext) {
            guard var turns = transcription.meetingTurns else { continue }
            var changed = false
            for index in turns.indices where turns[index].speakerID == sourceID {
                turns[index].speakerID = targetID
                changed = true
            }
            guard changed else { continue }
            apply(turns, to: transcription, library: library)
        }
        try? modelContext.save()
    }

    /// Deletes a voice from the library; every turn that referenced it reverts to the generic
    /// "Others" label rather than being left pointing at a dangling id.
    static func delete(id: String, library: SpeakerLibraryStore, modelContext: ModelContext) {
        library.delete(id: id)
        for transcription in meetingRecordings(modelContext: modelContext) {
            guard var turns = transcription.meetingTurns else { continue }
            var changed = false
            for index in turns.indices where turns[index].speakerID == id {
                turns[index].speakerID = nil
                changed = true
            }
            guard changed else { continue }
            apply(turns, to: transcription, library: library)
        }
        try? modelContext.save()
    }

    static func deleteAll(library: SpeakerLibraryStore, modelContext: ModelContext) {
        library.deleteAll()
        for transcription in meetingRecordings(modelContext: modelContext) {
            guard var turns = transcription.meetingTurns else { continue }
            let changed = turns.contains { $0.speakerID != nil }
            guard changed else { continue }
            for index in turns.indices { turns[index].speakerID = nil }
            apply(turns, to: transcription, library: library)
        }
        try? modelContext.save()
    }

    private static func rerenderMeetings(referencing ids: [String], library: SpeakerLibraryStore, modelContext: ModelContext) {
        let idSet = Set(ids)
        for transcription in meetingRecordings(modelContext: modelContext) {
            guard let turns = transcription.meetingTurns, turns.contains(where: { $0.speakerID.map(idSet.contains) == true })
            else { continue }
            apply(turns, to: transcription, library: library)
        }
        try? modelContext.save()
    }

    private static func apply(_ turns: [MeetingTurnRecord], to transcription: Transcription, library: SpeakerLibraryStore) {
        transcription.meetingTurns = turns
        transcription.text = MeetingSpeakerTranscriptRenderer.render(turns) { library.name(for: $0) }
    }

    private static func meetingRecordings(modelContext: ModelContext) -> [Transcription] {
        let descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { $0.isMeetingRecording && $0.deletedAt == nil })
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
