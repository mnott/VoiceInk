import Foundation
import Testing

@testable import VoiceInk

// MARK: - Rendering structured turns with speaker labels

struct MeetingSpeakerTranscriptRendererTests {
    private func turn(isMe: Bool, slot: Int? = nil, speakerID: String? = nil, text: String) -> MeetingTurnRecord {
        MeetingTurnRecord(isMe: isMe, diarizedSlot: slot, speakerID: speakerID, start: 0, end: 0, text: text)
    }

    @Test func meAndUnidentifiedOthersUseBracketLabels() {
        let text = MeetingSpeakerTranscriptRenderer.render(
            [turn(isMe: true, text: "hello"), turn(isMe: false, text: "hi back")], nameForSpeakerID: { _ in nil })
        #expect(text == "[Me:] hello\n\n[Others:] hi back")
    }

    @Test func identifiedButUnnamedVoiceShowsItsSpkID() {
        let text = MeetingSpeakerTranscriptRenderer.render(
            [turn(isMe: false, slot: 0, speakerID: "spk-abcd", text: "hello")], nameForSpeakerID: { _ in nil })
        #expect(text == "[spk-abcd:] hello")
    }

    @Test func namedVoiceShowsItsName() {
        let text = MeetingSpeakerTranscriptRenderer.render(
            [turn(isMe: false, slot: 0, speakerID: "spk-abcd", text: "hello")],
            nameForSpeakerID: { $0 == "spk-abcd" ? "Anna" : nil })
        #expect(text == "[Anna:] hello")
    }

    @Test func consecutiveTurnsFromTheSameSpeakerIDMergeIntoOneParagraph() {
        let text = MeetingSpeakerTranscriptRenderer.render(
            [
                turn(isMe: false, slot: 0, speakerID: "spk-abcd", text: "one"),
                turn(isMe: false, slot: 0, speakerID: "spk-abcd", text: "two"),
            ], nameForSpeakerID: { _ in nil })
        #expect(text == "[spk-abcd:] one two")
    }

    @Test func namingAVoiceLaterChangesTheRenderedLabelWithoutTouchingStoredTurns() {
        // The core "naming updates every past transcript" property: the same turns render
        // differently purely because the name resolver now returns a name - nothing about the
        // turn itself changes.
        let turns = [turn(isMe: false, slot: 0, speakerID: "spk-abcd", text: "hello")]
        #expect(MeetingSpeakerTranscriptRenderer.render(turns, nameForSpeakerID: { _ in nil }) == "[spk-abcd:] hello")
        #expect(
            MeetingSpeakerTranscriptRenderer.render(turns, nameForSpeakerID: { $0 == "spk-abcd" ? "Anna" : nil })
                == "[Anna:] hello")
    }
}

// MARK: - Speaker id generation

struct SpeakerIDGenerationTests {
    @Test func generatedIDsHaveTheExpectedPrefixAndLength() {
        let id = SpeakerMatching.generateID(excluding: [])
        #expect(id.hasPrefix("spk-"))
        #expect(id.count == "spk-".count + 4)
    }

    @Test func generationAvoidsEveryExcludedID() {
        // Force collisions on every 4-hex-char id so it must fall through to a longer one.
        let allFourHex = Set((0..<0x10000).map { String(format: "spk-%04x", $0) })
        let id = SpeakerMatching.generateID(excluding: allFourHex)
        #expect(!allFourHex.contains(id))
        #expect(id.hasPrefix("spk-"))
    }

    @Test func repeatedGenerationExcludingItsOwnOutputNeverRepeats() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let id = SpeakerMatching.generateID(excluding: seen)
            #expect(!seen.contains(id))
            seen.insert(id)
        }
    }
}

// MARK: - Rename commit gating

// Regression coverage for a live bug: a rename `TextField` bound to fire on every keystroke left
// a voice's name armed to be silently overwritten by whatever stray text (e.g. dictation typed at
// the cursor while the field kept focus after a previous Return) reached it next - "Guest" became
// "I" between two Meeting Capture sessions with no deliberate rename in between. The fix gates
// persistence behind an explicit commit point (Return / focus loss) and this pure comparison.
struct SpeakerRenameCommitGatingTests {
    @Test func unchangedDraftPersistsNothing() {
        #expect(SpeakerLibraryService.valueToPersist(draft: "Guest", currentName: "Guest") == nil)
    }

    @Test func draftMatchingNoPriorNamePersistsNothing() {
        #expect(SpeakerLibraryService.valueToPersist(draft: "", currentName: nil) == nil)
    }

    @Test func changedDraftPersistsTheNewValue() {
        #expect(SpeakerLibraryService.valueToPersist(draft: "Alice", currentName: "Guest") == "Alice")
    }

    @Test func firstNamePersistsFromNoPriorName() {
        #expect(SpeakerLibraryService.valueToPersist(draft: "Alice", currentName: nil) == "Alice")
    }
}

// MARK: - Matching / merging (pure, synthetic embeddings)

struct SpeakerMatchingTests {
    private func voice(id: String, embedding: [Float], count: Int = 1) -> SpeakerVoice {
        SpeakerVoice(
            id: id, name: nil, embedding: embedding, embeddingCount: count, sampleClipFileNames: [], firstHeard: .now,
            lastHeard: .now, meetingIDs: [])
    }

    @Test func identicalEmbeddingsHaveSimilarityOne() {
        let a: [Float] = [1, 0, 0]
        #expect(abs(SpeakerMatching.cosineSimilarity(a, a) - 1.0) < 0.0001)
    }

    @Test func orthogonalEmbeddingsHaveSimilarityZero() {
        #expect(SpeakerMatching.cosineSimilarity([1, 0], [0, 1]) == 0)
    }

    @Test func opositeEmbeddingsHaveSimilarityNegativeOne() {
        #expect(abs(SpeakerMatching.cosineSimilarity([1, 0], [-1, 0]) - (-1.0)) < 0.0001)
    }

    @Test func bestMatchFindsTheClosestVoiceAboveThreshold() {
        let voices = [voice(id: "spk-a", embedding: [1, 0, 0]), voice(id: "spk-b", embedding: [0, 1, 0])]
        let match = SpeakerMatching.bestMatch(for: [0.9, 0.1, 0], in: voices)
        #expect(match?.id == "spk-a")
    }

    @Test func belowThresholdReturnsNoMatch() {
        let voices = [voice(id: "spk-a", embedding: [1, 0, 0])]
        let match = SpeakerMatching.bestMatch(for: [0, 1, 0], in: voices)
        #expect(match == nil)
    }

    @Test func emptyLibraryNeverMatches() {
        #expect(SpeakerMatching.bestMatch(for: [1, 0, 0], in: []) == nil)
    }

    @Test func averagingWeightsByExistingSampleCount() {
        // 3 prior samples averaging to 0, one new sample of 4 -> (0*3 + 4) / 4 = 1.
        let averaged = SpeakerMatching.averaging(existing: [0], count: 3, new: [4])
        #expect(averaged == [1])
    }

    @Test func averagingWithNoPriorSamplesReturnsTheNewEmbeddingUnchanged() {
        #expect(SpeakerMatching.averaging(existing: [], count: 0, new: [5, 6]) == [5, 6])
    }

    @Test func mergeKeepsTargetIDAndUnionsMeetings() {
        var source = voice(id: "spk-source", embedding: [1, 0], count: 2)
        source.meetingIDs = [UUID()]
        var target = voice(id: "spk-target", embedding: [0, 1], count: 2)
        let sharedMeeting = UUID()
        target.meetingIDs = [sharedMeeting]
        source.meetingIDs.append(sharedMeeting)

        let merged = SpeakerMatching.merge(source: source, into: target)
        #expect(merged.id == "spk-target")
        #expect(merged.embeddingCount == 4)
        // Equal weight (2 samples each) average of [1,0] and [0,1] is [0.5, 0.5].
        #expect(merged.embedding == [0.5, 0.5])
        #expect(Set(merged.meetingIDs) == Set(source.meetingIDs + target.meetingIDs))
    }

    @Test func mergePrefersTargetsNameButFallsBackToSources() {
        var named = voice(id: "spk-a", embedding: [1, 0])
        named.name = "Anna"
        let unnamed = voice(id: "spk-b", embedding: [1, 0])

        #expect(SpeakerMatching.merge(source: unnamed, into: named).name == "Anna")
        #expect(SpeakerMatching.merge(source: named, into: unnamed).name == "Anna")
    }

    @Test func mergeKeepsTheIsMeFlagIfEitherSideHadIt() {
        var isMeVoice = voice(id: "spk-a", embedding: [1, 0])
        isMeVoice.isMe = true
        let plainVoice = voice(id: "spk-b", embedding: [0, 1])

        #expect(SpeakerMatching.merge(source: isMeVoice, into: plainVoice).isMe)
        #expect(SpeakerMatching.merge(source: plainVoice, into: isMeVoice).isMe)
    }

    @Test func voiceCreatedBeforeTheIsMeFieldExistedDecodesAsFalse() throws {
        // Mirrors a `speakers.json` written before `isMe` existed - the key is simply absent.
        let legacyJSON = """
            {
                "id": "spk-a", "embedding": [1, 0], "embeddingCount": 1, "sampleClipFileNames": [],
                "firstHeard": 0, "lastHeard": 0, "meetingIDs": []
            }
            """
        let decoded = try JSONDecoder().decode(SpeakerVoice.self, from: Data(legacyJSON.utf8))
        #expect(!decoded.isMe)
    }
}

// MARK: - Resolving a diarized slot's id (pure decision rule behind `assignSpeakers`)

struct ResolvedSpeakerIDTests {
    @Test func libraryMatchOverridesTheSessionIDWhenEmbeddingIsPresent() {
        let id = MeetingSpeakerIdentifier.resolvedSpeakerID(
            libraryMatchID: "spk-library", sessionID: "spk-session", freshID: "spk-fresh")
        #expect(id == "spk-library")
    }

    @Test func sessionIDIsReusedWhenThereIsNoLibraryMatch() {
        let id = MeetingSpeakerIdentifier.resolvedSpeakerID(libraryMatchID: nil, sessionID: "spk-session", freshID: "spk-fresh")
        #expect(id == "spk-session")
    }

    @Test func aFreshIDIsGeneratedOnlyWhenNeitherALibraryMatchNorASessionIDExists() {
        let id = MeetingSpeakerIdentifier.resolvedSpeakerID(libraryMatchID: nil, sessionID: nil, freshID: "spk-fresh")
        #expect(id == "spk-fresh")
    }
}

// MARK: - assignSpeakers never collapses a diarized slot to "Others", even without an embedder

@MainActor
struct MeetingSpeakerIdentifierAssignmentTests {
    private func turn(diarizedSlot: Int, start: Int) -> MeetingTurnRecord {
        MeetingTurnRecord(isMe: false, diarizedSlot: diarizedSlot, speakerID: nil, start: start, end: start + 32_000, text: "hello")
    }
    private let systemChannel = [Int16](repeating: 100, count: 400_000)

    @Test func distinctDiarizedSlotsGetDistinctIDsWhenTheEmbedderReturnsNil() async {
        // Reproduces the bug: no speaker-embedding model downloaded -> `embed` always returns nil.
        // Every diarized slot must still end up with its own stable id, never a shared/nil one.
        let turns = [turn(diarizedSlot: 0, start: 0), turn(diarizedSlot: 1, start: 100_000), turn(diarizedSlot: 2, start: 200_000)]
        let result = await MeetingSpeakerIdentifier.assignSpeakers(
            to: turns, systemChannel: systemChannel, meetingID: UUID(), library: SpeakerLibraryStore.shared, embed: { _ in nil })

        let ids = result.map(\.speakerID)
        #expect(ids.allSatisfy { $0 != nil })
        #expect(Set(ids).count == 3)
    }

    @Test func liveSessionIDsAreReusedWhenTheEmbedderReturnsNil() async {
        // The note must show the same ids the live chunks of this session already showed for these
        // slots, not freshly generated ones.
        let turns = [turn(diarizedSlot: 0, start: 0), turn(diarizedSlot: 1, start: 100_000)]
        let result = await MeetingSpeakerIdentifier.assignSpeakers(
            to: turns, systemChannel: systemChannel, meetingID: UUID(), library: SpeakerLibraryStore.shared,
            sessionIDBySlot: [0: "spk-0000", 1: "spk-0001"], embed: { _ in nil })

        #expect(result.first { $0.diarizedSlot == 0 }?.speakerID == "spk-0000")
        #expect(result.first { $0.diarizedSlot == 1 }?.speakerID == "spk-0001")
    }
}

// MARK: - Migration safety: the new optional field decodes as nil for existing records

struct MeetingTurnsMigrationSafetyTests {
    @Test func aRecordCreatedBeforeThisFieldHasNoTurnsAndDefaultsToNilData() {
        // Mirrors the existing `isMeetingRecording` convention: a new stored `Optional` property
        // needs no migration, and every pre-existing record simply decodes with it `nil`.
        let transcription = Transcription(text: "hello", duration: 1)
        #expect(transcription.meetingTurnsData == nil)
        #expect(transcription.meetingTurns == nil)
    }

    @Test func settingMeetingTurnsRoundTripsThroughTheJSONBackedProperty() throws {
        let transcription = Transcription(text: "", duration: 1, isMeetingRecording: true)
        let turns = [
            MeetingTurnRecord(isMe: true, diarizedSlot: nil, speakerID: nil, start: 0, end: 100, text: "hi"),
            MeetingTurnRecord(isMe: false, diarizedSlot: 0, speakerID: "spk-abcd", start: 100, end: 200, text: "hello"),
        ]
        transcription.meetingTurns = turns
        #expect(transcription.meetingTurnsData != nil)
        #expect(transcription.meetingTurns == turns)
    }
}
