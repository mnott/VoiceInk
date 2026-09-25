import FluidAudio
import Foundation
import SwiftData
import Testing

@testable import VoiceInk

/// Fake `WhisperModelProvider` and in-memory `ModelContext` only exist to satisfy
/// `TranscriptionServiceRegistry.init` - the stub below overrides `transcribe` itself, so no real
/// model ever runs (only regions/speakers/labels are under test here).
@MainActor
private final class HybridFakeWhisperModelProvider: WhisperModelProvider {
    var isModelLoaded: Bool { false }
    var whisperContext: WhisperContext? { nil }
    var loadedWhisperModel: WhisperModelFile? { nil }
    var availableModels: [WhisperModelFile] { [] }
}

@MainActor
private final class HybridStubTranscriptionServiceRegistry: TranscriptionServiceRegistry {
    override func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        "turn"
    }
}

/// Hybrid-capture proof (see `MeetingCaptureModeDetector`): a session with a system tap open AND
/// "Diarize Microphone" on must diarize BOTH channels in the same session - remote participants on
/// the system channel, room speakers on the mic - and keep them apart all the way into the
/// whole-meeting note. Regression for the note path, which used to collapse both channels' slot
/// spaces into one: `MeetingSpeakerIdentifier` grouped system slot 0 and mic slot 0 into one
/// person and enrolled the mic speaker from the *system* channel's audio.
@MainActor
struct MeetingHybridOfflineProofTests {
    private struct LabelledTurn {
        let speaker: MeetingTurnBuilder.Speaker
        let label: String
        let start: Int
        let end: Int
    }

    // MARK: - Note-path slot-space separation (pure, no model needed)

    @Test func hybridNoteKeepsMicAndSystemSlotSpacesSeparate() async {
        // A hybrid session's chunk turns: two mic-diarized room speakers and one system-diarized
        // remote speaker - note how both channels have a slot 0.
        let chunkTurns: [MeetingTurnTranscriptRenderer.TranscribedTurn] = [
            .init(speaker: .otherMic(0), text: "hello from the room", start: 0, end: 32_000),
            .init(speaker: .other(0), text: "hello from remote", start: 40_000, end: 72_000),
            .init(speaker: .otherMic(1), text: "room speaker two", start: 80_000, end: 112_000),
        ]
        let records = chunkTurns.map { MeetingTurnRecord($0) }
        #expect(records.map(\.isMicChannel) == [true, false, true], ".otherMic turns must persist their channel")
        #expect(Set(records.compactMap(\.diarizedKey)).count == 3, "channel + slot must be the grouping key")

        // System slot 0 and mic slot 0 must resolve to DIFFERENT ids - the mic tracker's ids must
        // not be answered from the system tracker's map, or vice versa (and the "zztest-" prefix
        // can never collide with a real library voice, keeping this hermetic).
        let channel = [Int16](repeating: 100, count: 200_000)
        let result = await MeetingSpeakerIdentifier.assignSpeakers(
            to: records, systemChannel: channel, micChannel: channel, meetingID: UUID(),
            library: SpeakerLibraryStore.shared,
            sessionIDBySlot: [0: "zztest-sys-0"], micSessionIDBySlot: [0: "zztest-mic-0", 1: "zztest-mic-1"],
            embed: { _ in nil })

        #expect(result.first { $0.isMicChannel && $0.diarizedSlot == 0 }?.speakerID == "zztest-mic-0")
        #expect(result.first { $0.isMicChannel && $0.diarizedSlot == 1 }?.speakerID == "zztest-mic-1")
        #expect(result.first { !$0.isMicChannel && $0.diarizedSlot == 0 }?.speakerID == "zztest-sys-0")

        // Carry-forward across retranscription is keyed the same way.
        let carried = MeetingSpeakerIdentifier.carryForwardSpeakerIDs(to: chunkTurns.map { MeetingTurnRecord($0) }, from: result)
        #expect(carried.first { $0.isMicChannel && $0.diarizedSlot == 0 }?.speakerID == "zztest-mic-0")
        #expect(carried.first { !$0.isMicChannel && $0.diarizedSlot == 0 }?.speakerID == "zztest-sys-0")
    }

    // MARK: - End-to-end hybrid session (model-gated, like MeetingInPersonOfflineProofTests)

    /// Feeds the real `dialogue.wav` (Daniel + the other voice) as the MIC channel and a
    /// single-voice system channel built from just the other voice's line spans as the SYSTEM
    /// channel, through the production path: two streaming `MeetingDiarizer`s fed 0.5 s blocks,
    /// `MeetingTurnTranscriber` (both diarizations at once), the live trackers'
    /// `MeetingMicSpeakerMapper` rendering, and the persisted-note leg (`MeetingTurnRecord` +
    /// `assignSpeakers` with each channel's own live session ids). No-ops if the fixture or the
    /// Nemotron 3 model aren't present, matching the other proof tests.
    @Test func hybridSessionLabelsTwoMicSpeakersAndASystemSpeakerInOneSession() async throws {
        guard let truth = MeetingDiarizationOfflineProofTests.loadTruth(),
            let mic = MeetingDiarizationOfflineProofTests.loadMono16k("/tmp/vi-test/dialogue.wav"),
            MeetingDiarizationModels.isDownloaded
        else {
            print("MeetingHybridOfflineProofTests: fixture or models not present, skipping")
            return
        }

        // System channel: only Karen's lines, silence elsewhere - the one "remote" participant.
        // The mic keeps every voice: the people sharing one room.
        var system = [Int16](repeating: 0, count: mic.count)
        for line in truth where line.speaker == "Karen" {
            let start = Int(line.start * 16000), end = min(Int(line.end * 16000), mic.count)
            if start < end { system.replaceSubrange(start..<end, with: mic[start..<end]) }
        }

        var report = ""
        func log(_ s: String) {
            print(s)
            report += s + "\n"
        }
        defer { try? report.write(toFile: "/tmp/vi-test/hybrid-proof-report.txt", atomically: true, encoding: .utf8) }

        guard let withoutMe = await Self.runHybridSession(mic: mic, system: system, meIdentitySlot: nil) else {
            log("MeetingHybridOfflineProofTests: streaming model failed to load, skipping")
            return
        }

        log("--- WITHOUT a \"this is me\" voice: nothing may render as Me ---")
        var anyMe = false
        var danielLabels: Set<String> = []
        var otherMicLabels: Set<String> = []
        for line in truth {
            guard let label = Self.majorityLabel(for: line, results: withoutMe.turns, micChannelOnly: true) else { continue }
            log("  mic \(line.speaker) -> \(label)")
            if label == "Me" { anyMe = true }
            if line.speaker == "Daniel" { danielLabels.insert(label) } else { otherMicLabels.insert(label) }
        }
        let allMicLabels = danielLabels.union(otherMicLabels)
        #expect(!anyMe, "no voice is flagged \"this is me\" - nothing may render as [Me:]")
        #expect(allMicLabels.count >= 2, "the mic channel must hold at least two distinct room speakers")
        #expect(danielLabels.count == 1, "Daniel's lines must land on one stable mic speaker")
        #expect(danielLabels.isDisjoint(with: otherMicLabels), "Daniel must be distinct from the other room voices")

        let systemLabels = Set(withoutMe.turns.compactMap { turn -> String? in
            guard case .other = turn.speaker else { return nil }
            return turn.label
        })
        log("  system labels: \(systemLabels.sorted())")
        #expect(!systemLabels.isEmpty, "the system channel's voice must produce turns")
        #expect(systemLabels.allSatisfy { $0.hasPrefix("zztest-sys-") }, "system turns must render through the system tracker")
        #expect(systemLabels.count == 1, "the system channel holds exactly one remote voice")

        // Daniel's first line tells us which mic slot he is - exactly what a user would click
        // "This is me" on. Ids are prefixed "zztest-" so they can never collide with the real
        // speaker library, keeping this test hermetic.
        guard let firstDaniel = truth.first(where: { $0.speaker == "Daniel" }),
            let danielSlot = Self.majoritySlot(for: firstDaniel, results: withoutMe.turns)
        else {
            log("MeetingHybridOfflineProofTests: no Daniel line/slot found, skipping the \"me\" variant")
            return
        }

        guard let withMe = await Self.runHybridSession(mic: mic, system: system, meIdentitySlot: danielSlot) else {
            log("MeetingHybridOfflineProofTests: streaming model failed to load on the second run, skipping")
            return
        }

        log("--- WITH Daniel's mic slot marked \"this is me\" ---")
        var correct = 0
        var total = 0
        for line in truth {
            guard let label = Self.majorityLabel(for: line, results: withMe.turns, micChannelOnly: true) else { continue }
            let expectMe = line.speaker == "Daniel"
            let isCorrect = expectMe ? label == "Me" : (label != "Me" && !label.hasPrefix("zztest-sys-"))
            total += 1
            if isCorrect { correct += 1 }
            log("  mic \(line.speaker) -> \(label) \(isCorrect ? "OK" : "WRONG")")
        }
        log("hybrid mic \"me\" labelling: \(correct)/\(total) lines correct")
        #expect(correct == total)

        let withMeSystemLabels = Set(withMe.turns.compactMap { turn -> String? in
            guard case .other = turn.speaker else { return nil }
            return turn.label
        })
        #expect(withMeSystemLabels.allSatisfy { $0.hasPrefix("zztest-sys-") })
        #expect(!withMeSystemLabels.contains("Me"), "the remote speaker must stay separate from Me")

        // Note leg: the persisted record keeps the channels' slot spaces apart, and each slot
        // carries the id its live tracker showed - "zztest-me" for Daniel, distinct ids for the
        // other room voice and the remote voice.
        let records = withMe.turns.map {
            MeetingTurnRecord(.init(speaker: $0.speaker, text: $0.label, start: $0.start, end: $0.end))
        }
        // Each slot's live id is the id its tracker resolved (rendered labels are for humans -
        // Daniel's slot legitimately renders as "Me", which is not an id).
        let micSessionIDs = withMe.micIDs
        let systemSessionIDs = withMe.systemIDs
        let result = await MeetingSpeakerIdentifier.assignSpeakers(
            to: records, systemChannel: system, micChannel: mic, meetingID: UUID(),
            library: SpeakerLibraryStore.shared,
            sessionIDBySlot: systemSessionIDs, micSessionIDBySlot: micSessionIDs, embed: { _ in nil })
        let danielNote = result.first { $0.isMicChannel && $0.diarizedSlot == danielSlot }
        let remoteNote = result.first { !$0.isMicChannel && $0.diarizedSlot != nil }
        #expect(danielNote?.speakerID == "zztest-me", "Daniel's mic slot must keep its live id in the note")
        #expect(remoteNote?.speakerID?.hasPrefix("zztest-sys-") == true, "the remote slot must keep its system-channel id")
        #expect(danielNote?.speakerID != remoteNote?.speakerID, "mic and system slot spaces must never merge")
    }

    // MARK: - One hybrid session run (two diarizers + transcriber + trackers + renderer)

    /// - Parameter meIdentitySlot: `nil` runs with no library match at all; non-`nil` injects, via
    ///   `MeetingLiveSpeakerTracker.embed`/`matchOrRegister` (the same seam the in-person proof
    ///   uses), a library match flagging that one mic slot "this is me".
    private static func runHybridSession(
        mic: [Int16], system: [Int16], meIdentitySlot: Int?
    ) async -> (turns: [LabelledTurn], micIDs: [Int: String], systemIDs: [Int: String])? {
        guard let micDiarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig),
            let systemDiarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig)
        else { return nil }

        // Both streaming diarizers, fed in 0.5 s blocks from session sample 0 - the same
        // backlog-replay invariant the other proof tests exercise.
        for (diarizer, channel) in [(micDiarizer, mic), (systemDiarizer, system)] {
            var i = 0
            while i < channel.count {
                let end = min(i + 8000, channel.count)
                diarizer.append(Array(channel[i..<end]))
                i = end
            }
            diarizer.finish()
        }
        let micDiarization = micDiarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: mic.count)
        let systemDiarization = systemDiarizer.attribute(chunkStartGlobal: 0, chunkEndGlobal: system.count)

        let stubRegistry = HybridStubTranscriptionServiceRegistry(
            modelProvider: HybridFakeWhisperModelProvider(), modelsDirectory: FileManager.default.temporaryDirectory,
            modelContext: ModelContext(
                try! ModelContainer(
                    for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))))
        let model = NativeAppleModel(
            name: "stub", displayName: "stub", description: "stub", isMultilingualModel: false, supportedLanguages: [:])
        let chunk = await MeetingTurnTranscriber.transcribe(
            mic: mic, system: system, model: model, requestContext: .currentDefaults, serviceRegistry: stubRegistry,
            systemDiarization: systemDiarization, micDiarization: micDiarization)

        let micTracker = MeetingLiveSpeakerTracker()
        let systemTracker = MeetingLiveSpeakerTracker()
        // Hermetic in both runs: no embedding traffic reaches the real `SpeakerLibraryStore`
        // ("zztest-" can never collide with a real library voice). A nil embed ends `observe`'s
        // match pipeline early, so slots keep their deterministic provisional ids.
        systemTracker.embed = { _ in nil }
        var lastObservedSlot = -1
        if let meIdentitySlot {
            micTracker.embed = { _ in [Float(lastObservedSlot)] }
            micTracker.matchOrRegister = { embedding, _, _ in
                Int(embedding.first ?? -1) == meIdentitySlot ? ("zztest-me", nil) : ("zztest-mic-\(Int(embedding.first ?? -1))", nil)
            }
        }
        var next = 0
        micTracker.generateProvisionalID = { _ in defer { next += 1 }; return "zztest-mic-\(next)" }
        if meIdentitySlot == nil {
            micTracker.embed = { _ in nil }
        }
        var nextSystemID = 0
        systemTracker.generateProvisionalID = { _ in defer { nextSystemID += 1 }; return "zztest-sys-\(nextSystemID)" }

        let meetingID = UUID()
        var results: [LabelledTurn] = []
        for turn in chunk.turns {
            switch turn.speaker {
            case .otherMic(let slot?):
                micTracker.recordTurn(.remote(slot: slot))
                if turn.start < turn.end, turn.end <= mic.count {
                    lastObservedSlot = slot
                    let task = micTracker.observe(slot: slot, samples: mic[turn.start..<turn.end], meetingID: meetingID)
                    await task?.value
                }
            case .other(let slot?):
                systemTracker.recordTurn(.remote(slot: slot))
                if turn.start < turn.end, turn.end <= system.count {
                    let task = systemTracker.observe(slot: slot, samples: system[turn.start..<turn.end], meetingID: meetingID)
                    await task?.value
                }
            default:
                break
            }
            results.append(
                LabelledTurn(
                    speaker: turn.speaker, label: Self.label(for: turn.speaker, micTracker: micTracker, systemTracker: systemTracker, isMeVoice: { $0 == "zztest-me" }),
                    start: turn.start, end: turn.end))
        }

        // Exercise the real renderer too - the actual text `VoiceInkEngine+Meeting` would paste.
        let rendered = MeetingTurnTranscriptRenderer.render(chunk.turns) { speaker in
            Self.label(for: speaker, micTracker: micTracker, systemTracker: systemTracker, isMeVoice: { $0 == "zztest-me" })
        }
        #expect(!rendered.isEmpty)

        // Each slot's live id is the id its tracker resolved (rendered labels are for humans -
        // Daniel's slot legitimately renders as "Me", which is not an id).
        func sessionIDs(micChannel: Bool, tracker: MeetingLiveSpeakerTracker) -> [Int: String] {
            var ids: [Int: String] = [:]
            for turn in results {
                let slot: Int?
                switch (micChannel, turn.speaker) {
                case (true, .otherMic(let s?)): slot = s
                case (false, .other(let s?)): slot = s
                default: slot = nil
                }
                guard let slot, let id = tracker.state.libraryID(forSlot: slot) ?? tracker.state.provisionalID(forSlot: slot)
                else { continue }
                ids[slot] = id
            }
            return ids
        }
        return (results, sessionIDs(micChannel: true, tracker: micTracker), sessionIDs(micChannel: false, tracker: systemTracker))
    }

    /// Mirrors `VoiceInkEngine+Meeting.transcribeMeetingChunk`'s label resolution: `.otherMic`
    /// through `MeetingMicSpeakerMapper` + the mic tracker, `.other` through the system tracker.
    private static func label(
        for speaker: MeetingTurnBuilder.Speaker,
        micTracker: MeetingLiveSpeakerTracker, systemTracker: MeetingLiveSpeakerTracker, isMeVoice: (String) -> Bool
    ) -> String {
        switch speaker {
        case .me: return "Me"
        case .other(nil): return "Others"
        case .other(let slot?): return systemTracker.state.label(for: .remote(slot: slot))
        case .otherMic(nil): return "Others"
        case .otherMic(let slot?):
            return MeetingMicSpeakerMapper.label(
                libraryID: micTracker.state.libraryID(forSlot: slot), isMeVoice: isMeVoice,
                fallback: micTracker.state.label(for: .remote(slot: slot)))
        }
    }

    // MARK: - Grading against the hand-authored ground truth

    /// Majority label over turns overlapping `line` - `micChannelOnly` grades room voices against
    /// the mic channel's turns only (the same audio also plays on the system channel here).
    private static func majorityLabel(for line: MeetingDiarizationOfflineProofTests.TruthLine, results: [LabelledTurn], micChannelOnly: Bool) -> String? {
        let lineStart = Int(line.start * 16000), lineEnd = Int(line.end * 16000)
        var overlapByLabel: [String: Int] = [:]
        for r in results where r.speaker.isMicChannel == micChannelOnly {
            let start = max(r.start, lineStart), end = min(r.end, lineEnd)
            guard end > start else { continue }
            overlapByLabel[r.label, default: 0] += end - start
        }
        return overlapByLabel.max { $0.value < $1.value }?.key
    }

    private static func majoritySlot(for line: MeetingDiarizationOfflineProofTests.TruthLine, results: [LabelledTurn]) -> Int? {
        let lineStart = Int(line.start * 16000), lineEnd = Int(line.end * 16000)
        var overlapBySlot: [Int: Int] = [:]
        for r in results {
            guard case .otherMic(let slot?) = r.speaker else { continue }
            let start = max(r.start, lineStart), end = min(r.end, lineEnd)
            guard end > start else { continue }
            overlapBySlot[slot, default: 0] += end - start
        }
        return overlapBySlot.max { $0.value < $1.value }?.key
    }
}
