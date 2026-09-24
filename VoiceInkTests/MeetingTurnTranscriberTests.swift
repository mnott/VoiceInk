import Foundation
import SwiftData
import Testing

@testable import VoiceInk

/// Fake `WhisperModelProvider` and in-memory `ModelContext` only exist to satisfy
/// `TranscriptionServiceRegistry.init` - `StubTranscriptionServiceRegistry` overrides `transcribe`
/// itself, so none of the real services these normally back are ever reached.
@MainActor
private final class FakeWhisperModelProvider: WhisperModelProvider {
    var isModelLoaded: Bool { false }
    var whisperContext: WhisperContext? { nil }
    var loadedWhisperModel: WhisperModelFile? { nil }
    var availableModels: [WhisperModelFile] { [] }
}

/// Returns `texts[callCount]` in turn-processing order instead of running a real model - lets a
/// test dictate exactly what ASR text each VAD-detected turn "transcribes" to.
@MainActor
private final class StubTranscriptionServiceRegistry: TranscriptionServiceRegistry {
    private let texts: [String]
    private(set) var callCount = 0

    init(texts: [String]) {
        self.texts = texts
        super.init(
            modelProvider: FakeWhisperModelProvider(), modelsDirectory: FileManager.default.temporaryDirectory,
            modelContext: ModelContext(
                try! ModelContainer(for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))))
    }

    override func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        defer { callCount += 1 }
        return callCount < texts.count ? texts[callCount] : ""
    }
}

/// Covers the punctuation-only-turn drop in `MeetingTurnTranscriber.transcribe` (see its `filtered`
/// guard): a VAD-detected turn whose ASR text has no letter/digit must not reach the returned
/// turns, on either channel, without disturbing the order or speaker of the turns around it.
@MainActor
struct MeetingTurnTranscriberTests {
    private static let sampleRate = MeetingVAD.sampleRate

    private static func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func tone(seconds: Double, amplitude: Int16 = 6000, frequency: Double = 400) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            Int16(clamping: Int((Double(amplitude) * sin(2 * Double.pi * frequency * Double(i) / sampleRate)).rounded()))
        }
    }

    /// `slots[i]` is `true` when this channel speaks during slot `i`; every other slot is silence
    /// on this channel. 2 s between slots clears both `MeetingVAD`'s hangover and
    /// `MeetingTurnBuilder`'s adjacent-same-speaker merge gaps (<=1.5 s), so every slot lands as
    /// its own turn regardless of channel.
    private static func channel(owning slots: [Bool]) -> [Int16] {
        var out = silence(seconds: 0.5)
        for owns in slots {
            out += owns ? tone(seconds: 0.4) : silence(seconds: 0.4)
            out += silence(seconds: 2.0)
        }
        return out
    }

    @Test func punctuationOnlyTurnsAreDroppedOnBothChannelsWithoutDisturbingKeptNeighbours() async {
        // Slot -> (channel, text). Mic carries the kept turns, system carries the dropped ones, so
        // a wrong result unambiguously means either the filter or the ordering broke.
        let micOwns = [true, false, true, false, true, false, false]
        let systemOwns = [false, true, false, true, false, true, true]
        let texts = ["Ja.", "-", "Okay", "...", "12", " - ", "—"]

        let mic = Self.channel(owning: micOwns)
        let system = Self.channel(owning: systemOwns)
        let registry = StubTranscriptionServiceRegistry(texts: texts)
        let model = NativeAppleModel(
            name: "stub", displayName: "stub", description: "stub", isMultilingualModel: false, supportedLanguages: [:])

        let result = await MeetingTurnTranscriber.transcribe(
            mic: mic, system: system, model: model, requestContext: .currentDefaults, serviceRegistry: registry)

        #expect(registry.callCount == texts.count, "every VAD-detected slot must still reach transcription")
        #expect(result.turns.map(\.text) == ["Ja.", "Okay", "12"])
        #expect(result.turns.allSatisfy { $0.speaker == .me }, "punctuation-only Others turns dropped; kept Me turns keep their speaker")
        let starts = result.turns.map(\.start)
        #expect(starts == starts.sorted(), "kept turns keep their chronological order across the dropped ones")
    }
}
