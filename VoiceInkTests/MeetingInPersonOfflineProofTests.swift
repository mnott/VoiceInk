import FluidAudio
import Foundation
import SwiftData
import Testing

@testable import VoiceInk

/// Fake `WhisperModelProvider` and in-memory `ModelContext` only exist to satisfy
/// `TranscriptionServiceRegistry.init` - `StubTranscriptionServiceRegistry` below overrides
/// `transcribe` itself, so none of the real services these normally back are ever reached.
@MainActor
private final class FakeWhisperModelProvider: WhisperModelProvider {
    var isModelLoaded: Bool { false }
    var whisperContext: WhisperContext? { nil }
    var loadedWhisperModel: WhisperModelFile? { nil }
    var availableModels: [WhisperModelFile] { [] }
}

/// Stands in for the real Whisper/cloud transcription round trip: the point of this proof is
/// regions, speakers and labels (see this file's test doc comment), not transcript text, so every
/// clip gets a placeholder instead of actually running a model.
@MainActor
private final class StubTranscriptionServiceRegistry: TranscriptionServiceRegistry {
    private(set) var callCount = 0

    override func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        defer { callCount += 1 }
        return "turn \(callCount)"
    }
}

/// Empirical, end-to-end proof of the in-person path (mic-channel diarization - see
/// `MeetingCaptureModeDetector`) that can't be exercised live on a Mac: sound the Mac itself plays
/// is captured by the system tap and cancelled back out of the mic by the echo canceller, so a
/// live two-voice "in-person" recording can't actually be produced on this hardware. Instead this
/// feeds the same real `dialogue.wav`/`timeline.tsv` fixture `MeetingDiarizationOfflineProofTests`
/// uses - there playing the *system* channel of a remote call - as the *mic* channel of an
/// in-person session with a silent system channel, and drives it through the exact production
/// path: a streaming `MeetingDiarizer` fed 0.5 s blocks from session sample 0, chunked at the real
/// `MeetingAutoSendEvaluator`/`MeetingAutoSendPolicy` boundaries, `MeetingTurnTranscriber`'s mic
/// path (`micDiarization`, `.otherMic` labels), `MeetingTurnBuilder`, a real
/// `MeetingLiveSpeakerTracker`, and `MeetingTurnTranscriptRenderer` + `MeetingMicSpeakerMapper` -
/// everything `VoiceInkEngine+Meeting.transcribeMeetingChunk`/`observeLiveSpeakers` do, just called
/// directly instead of through the `@MainActor` engine. Transcription text itself is stubbed (see
/// `StubTranscriptionServiceRegistry`) since only regions/speakers/labels are under test here.
/// No-ops if the fixture or the Nemotron 3 model aren't present, matching
/// `MeetingDiarizationOfflineProofTests`.
@MainActor
struct MeetingInPersonOfflineProofTests {
    private typealias TruthLine = MeetingDiarizationOfflineProofTests.TruthLine
    private typealias Speaker = MeetingTurnBuilder.Speaker

    private struct LabelledTurn {
        let speaker: Speaker
        let label: String
        let start: Int
        let end: Int
    }

    @Test func inPersonMicDiarizationLabelsBySessionIdWithoutAMeVoiceAndAsMeWithOne() async throws {
        guard let truth = MeetingDiarizationOfflineProofTests.loadTruth(),
            let mic = MeetingDiarizationOfflineProofTests.loadMono16k("/tmp/vi-test/dialogue.wav"),
            MeetingDiarizationModels.isDownloaded
        else {
            print("MeetingInPersonOfflineProofTests: fixture or models not present, skipping")
            return
        }
        let system = [Int16](repeating: 0, count: mic.count)

        var report = ""
        func log(_ s: String) {
            print(s)
            report += s + "\n"
        }
        defer { try? report.write(toFile: "/tmp/vi-test/in-person-proof-report.txt", atomically: true, encoding: .utf8) }

        let boundaries = Self.chunkBoundaries(mic: mic, system: system)
        log("=== simulated chunk boundaries (MeetingAutoSendEvaluator, real policy) ===")
        for b in boundaries { log("  \(Double(b.start) / 16000)s - \(Double(b.end) / 16000)s") }

        guard let without = await Self.runInPersonSession(mic: mic, system: system, boundaries: boundaries, meIdentitySlot: nil)
        else {
            log("MeetingInPersonOfflineProofTests: streaming model failed to load, skipping")
            return
        }

        log("--- WITHOUT a \"this is me\" voice: every mic speaker must render by session id ---")
        var everRenderedMe = false
        var danielLabels: Set<String> = []
        var femaleLabels: Set<String> = []
        for line in truth {
            guard let label = Self.majorityLabel(for: line, results: without) else { continue }
            log("  \(line.speaker) -> \(label)")
            if label == "Me" { everRenderedMe = true }
            if line.speaker == "Daniel" { danielLabels.insert(label) } else { femaleLabels.insert(label) }
        }
        #expect(!everRenderedMe, "no voice is flagged \"this is me\" yet - nothing may render as [Me:]")
        #expect(danielLabels.isDisjoint(with: femaleLabels), "Daniel and the female voices must still get distinct session ids")

        // Build the library voice from Daniel's first line: the same-audio, same-config,
        // identically-fed diarizer run above already told us which mic-diarized slot that line
        // landed in - exactly what a user would click "This is me" on after hearing that turn.
        guard let firstDaniel = truth.first(where: { $0.speaker == "Daniel" }),
            let danielSlot = Self.majoritySlot(for: firstDaniel, results: without)
        else {
            log("MeetingInPersonOfflineProofTests: no Daniel line/slot found, skipping the \"me\" variant")
            return
        }
        let embeddingModelAvailable = MeetingSpeakerEmbeddingModels.isDownloaded
        log(
            "--- Daniel's first line (\(firstDaniel.start)-\(firstDaniel.end)s) maps to mic-diarized slot \(danielSlot); "
                + "speaker-embedding model downloaded: \(embeddingModelAvailable) ---")
        if !embeddingModelAvailable {
            log(
                "embedding model absent on this host - injecting the \"me\" slot mapping via "
                    + "MeetingLiveSpeakerTracker's embed/matchOrRegister seam instead of a real embedding")
        }

        guard
            let with = await Self.runInPersonSession(
                mic: mic, system: system, boundaries: boundaries, meIdentitySlot: danielSlot)
        else {
            log("MeetingInPersonOfflineProofTests: streaming model failed to load on the second run, skipping")
            return
        }

        log("--- WITH Daniel's voice marked \"this is me\" ---")
        var correct = 0
        var total = 0
        for line in truth {
            guard let label = Self.majorityLabel(for: line, results: with) else { continue }
            let expectMe = line.speaker == "Daniel"
            let isCorrect = expectMe ? label == "Me" : label != "Me"
            total += 1
            if isCorrect { correct += 1 }
            log("  \(line.speaker) -> \(label) \(isCorrect ? "OK" : "WRONG")")
        }
        log("in-person \"me\" labelling: \(correct)/\(total) lines correct")
        #expect(correct == total)
    }

    // MARK: - Chunk boundaries (real MeetingAutoSendEvaluator/MeetingAutoSendPolicy)

    /// Mirrors `MeetingAutoSendEvaluatorTests.run`, but at the drain timer's real 0.5 s tick (not
    /// 1 s) and returning the actual chunk sample ranges instead of just trigger silence
    /// durations - one per automatic trigger, plus a final forced-full-release chunk for whatever
    /// is left, the way `toggleMeetingCapture`'s stop-side `cut(forceFullRelease: true)` behaves.
    private static func chunkBoundaries(mic: [Int16], system: [Int16]) -> [(start: Int, end: Int)] {
        let sampleRate = MeetingVAD.sampleRate
        let tickSamples = 8_000  // 0.5s @ 16kHz - MeetingAudioCapture's drain tick
        var micState = MeetingVAD.State.initial
        var systemState = MeetingVAD.State.initial
        var tracker = MeetingAutoSendTracker()
        var chunkPendingBaseOffset = 0
        var boundaries: [(start: Int, end: Int)] = []

        var i = 0
        while i < mic.count {
            let end = min(i + tickSamples, mic.count)
            let result = MeetingAutoSendEvaluator.step(
                mic: Array(mic[i..<end]), system: Array(system[i..<end]), sampleRate: sampleRate, autoSendEnabled: true,
                micVADState: micState, systemVADState: systemState, tracker: tracker)
            micState = result.micVADState
            systemState = result.systemVADState
            tracker = result.tracker

            if result.shouldTrigger {
                let boundary = MeetingAutoSendEvaluator.cutBoundary(
                    micVADState: micState, systemVADState: systemState,
                    chunkPendingBaseOffset: chunkPendingBaseOffset, forceFullRelease: false)
                let pendingLength = end - chunkPendingBaseOffset
                let delivered = boundary == .max ? pendingLength : min(boundary, pendingLength)
                if delivered > 0 {
                    boundaries.append((chunkPendingBaseOffset, chunkPendingBaseOffset + delivered))
                    chunkPendingBaseOffset += delivered
                }
                tracker.resetAfterChunkSent()
            }
            i = end
        }
        if chunkPendingBaseOffset < mic.count {
            boundaries.append((chunkPendingBaseOffset, mic.count))
        }
        return boundaries
    }

    // MARK: - One full in-person session run (streaming diarizer + transcriber + tracker + renderer)

    /// - Parameter meIdentitySlot: `nil` runs with no library voice at all - the real
    ///   `MeetingSpeakerEmbedder`/`SpeakerLibraryStore` seam, which returns no match since the
    ///   embedding model isn't downloaded on this host (same as production would with it absent).
    ///   Non-`nil` injects, via `MeetingLiveSpeakerTracker.embed`/`matchOrRegister` (the same seam
    ///   `MeetingLiveSpeakerTrackerTests` unit-tests with), a library match that flags that one
    ///   mic-diarized slot "this is me" - standing in for the real embedding model.
    private static func runInPersonSession(
        mic: [Int16], system: [Int16], boundaries: [(start: Int, end: Int)], meIdentitySlot: Int?
    ) async -> [LabelledTurn]? {
        guard let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.streamingConfig) else {
            return nil
        }

        // Streaming mic diarizer, fed in 0.5 s blocks from session sample 0 - the backlog-replay
        // invariant (see MeetingDiarizationOfflineProofTests): no attach delay here, so nothing
        // needs to go through MeetingDiarizerAttachBacklog first.
        var i = 0
        let feedBlockSamples = 8_000
        while i < mic.count {
            let end = min(i + feedBlockSamples, mic.count)
            diarizer.append(Array(mic[i..<end]))
            i = end
        }
        diarizer.finish()

        let micSpeakerTracker = MeetingLiveSpeakerTracker()
        var isMeVoiceIDs: Set<String> = []
        var lastObservedSlot = -1
        if let meIdentitySlot {
            micSpeakerTracker.embed = { _ in [Float(lastObservedSlot)] }
            micSpeakerTracker.matchOrRegister = { embedding, _, _ in
                let slot = Int(embedding.first ?? -1)
                if slot == meIdentitySlot {
                    isMeVoiceIDs.insert("spk-me")
                    return ("spk-me", nil)
                }
                return ("spk-fake-\(slot)", nil)
            }
        }

        let stubRegistry = StubTranscriptionServiceRegistry(
            modelProvider: FakeWhisperModelProvider(), modelsDirectory: FileManager.default.temporaryDirectory,
            modelContext: ModelContext(
                try! ModelContainer(
                    for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))))
        let model = NativeAppleModel(
            name: "stub", displayName: "stub", description: "stub", isMultilingualModel: false, supportedLanguages: [:])
        let meetingID = UUID()

        var micNoiseFloor = 0.0
        var systemNoiseFloor = 0.0
        var results: [LabelledTurn] = []

        for (chunkStart, chunkEnd) in boundaries {
            let chunkMic = Array(mic[chunkStart..<chunkEnd])
            let chunkSystem = Array(system[chunkStart..<chunkEnd])
            let micDiarization = diarizer.attribute(chunkStartGlobal: chunkStart, chunkEndGlobal: chunkEnd)

            let chunkResult = await MeetingTurnTranscriber.transcribe(
                mic: chunkMic, system: chunkSystem, model: model, requestContext: .currentDefaults,
                serviceRegistry: stubRegistry, micNoiseFloor: micNoiseFloor, systemNoiseFloor: systemNoiseFloor,
                systemDiarization: nil, micDiarization: micDiarization)
            micNoiseFloor = chunkResult.micNoiseFloor
            systemNoiseFloor = chunkResult.systemNoiseFloor

            for turn in chunkResult.turns {
                if case .otherMic(let slot?) = turn.speaker {
                    micSpeakerTracker.recordTurn(.remote(slot: slot))
                    if turn.start < turn.end, turn.end <= chunkMic.count {
                        lastObservedSlot = slot
                        let task = micSpeakerTracker.observe(
                            slot: slot, samples: chunkMic[turn.start..<turn.end], meetingID: meetingID)
                        await task?.value
                    }
                }

                let label = Self.label(for: turn.speaker, tracker: micSpeakerTracker, isMeVoice: { isMeVoiceIDs.contains($0) })
                results.append(LabelledTurn(speaker: turn.speaker, label: label, start: chunkStart + turn.start, end: chunkStart + turn.end))
            }
        }

        // Exercise the real renderer too - the actual `[Me:]`/`[spk-XXXX:]` text
        // `VoiceInkEngine+Meeting` would paste, from the exact same speaker/label resolution.
        let rendered = MeetingTurnTranscriptRenderer.render(
            results.map { .init(speaker: $0.speaker, text: "x", start: $0.start, end: $0.end) }
        ) { speaker in
            guard case .otherMic(let slot?) = speaker else { return nil }
            return Self.label(for: speaker, tracker: micSpeakerTracker, isMeVoice: { isMeVoiceIDs.contains($0) })
        }
        #expect(!rendered.isEmpty)

        return results
    }

    /// Mirrors `VoiceInkEngine+Meeting.transcribeMeetingChunk`'s `.otherMic` branch: a live
    /// library match flagged "this is me" (`MeetingMicSpeakerMapper`) renders `[Me:]`; otherwise
    /// the slot's session id (or name, once matched to a named-but-not-me voice).
    private static func label(for speaker: Speaker, tracker: MeetingLiveSpeakerTracker, isMeVoice: (String) -> Bool) -> String {
        switch speaker {
        case .me: return "Me"
        case .other(nil), .otherMic(nil): return "Others"
        case .other(let idx?): return String(format: "spk-%04x", idx)
        case .otherMic(let slot?):
            return MeetingMicSpeakerMapper.label(
                libraryID: tracker.state.libraryID(forSlot: slot), isMeVoice: isMeVoice,
                fallback: tracker.state.label(for: .remote(slot: slot)))
        }
    }

    // MARK: - Grading against the hand-authored ground truth

    private static func majorityLabel(for line: TruthLine, results: [LabelledTurn]) -> String? {
        let lineStart = Int(line.start * 16000)
        let lineEnd = Int(line.end * 16000)
        var overlapByLabel: [String: Int] = [:]
        for r in results {
            let start = max(r.start, lineStart)
            let end = min(r.end, lineEnd)
            guard end > start else { continue }
            overlapByLabel[r.label, default: 0] += end - start
        }
        return overlapByLabel.max { $0.value < $1.value }?.key
    }

    private static func majoritySlot(for line: TruthLine, results: [LabelledTurn]) -> Int? {
        let lineStart = Int(line.start * 16000)
        let lineEnd = Int(line.end * 16000)
        var overlapBySlot: [Int: Int] = [:]
        for r in results {
            guard case .otherMic(let slot?) = r.speaker else { continue }
            let start = max(r.start, lineStart)
            let end = min(r.end, lineEnd)
            guard end > start else { continue }
            overlapBySlot[slot, default: 0] += end - start
        }
        return overlapBySlot.max { $0.value < $1.value }?.key
    }
}
