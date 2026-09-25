import Foundation
import SwiftData
import Testing

@testable import VoiceInk

/// Regression tests for `MeetingRecordingWriter`'s RIFF/WAVE reading: the old readers hardcoded
/// the writer's own 44-byte header, so a foreign wav carrying chunks before `data` (ffmpeg adds a
/// 34-byte `LIST`) desynced both channels, and chunks after `data` leaked in as garbage frames.
/// The fixture tests run against a real meeting recording via `MEETING_WAV` (skip when unset) and
/// the full end-to-end transcript via `MEETING_FULL=1` - the latter runs the production
/// `MeetingRecordingTranscriber` + speaker-identification + note-renderer pipeline over the whole
/// file and is exempt from the 60 s per-test cap (see the task's own long-timeout invocation).
@MainActor
struct MeetingWAVReaderTests {
    // MARK: - Synthetic RIFF parsing

    private struct Chunk {
        let id: String
        let payload: [UInt8]
    }

    /// Builds a stereo 16 kHz PCM wav from raw pieces: optional extra chunks before/after `data`,
    /// with odd-sized payloads exercising the RIFF pad-byte rule.
    private static func wav(pre: [Chunk] = [], post: [Chunk] = [], samples: [Int16]) -> Data {
        var body = Data()
        func append(chunk: Chunk) {
            body.append(contentsOf: Array(chunk.id.utf8))
            body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(chunk.payload.count)))
            body.append(contentsOf: chunk.payload)
            if chunk.payload.count % 2 == 1 { body.append(0) }  // RIFF pad byte
        }
        for chunk in pre { append(chunk: chunk) }

        body.append(contentsOf: Array("fmt ".utf8))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(16)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(1)))  // PCM
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(2)))  // stereo
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(16000)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(64000)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(4)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(16)))

        var payload = Data()
        samples.withUnsafeBufferPointer { payload.append(contentsOf: UnsafeRawBufferPointer($0)) }
        append(chunk: Chunk(id: "data", payload: [UInt8](payload)))
        for chunk in post { append(chunk: chunk) }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(4 + body.count)))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: body)
        return wav
    }

    private static func write(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-wav-reader-\(name)-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// Left and right carry distinguishable ramps so any swap or shift shows in the values.
    private static func rampFrames(_ count: Int) -> [Int16] {
        (0..<count).flatMap { i in [Int16(clamping: 1000 + i), Int16(clamping: -30_000 - i)] }
    }

    @Test func canonicalWriterOutputRoundTrips() throws {
        let frames = Self.rampFrames(64)
        var mic: [Int16] = []
        var system: [Int16] = []
        for i in stride(from: 0, to: frames.count, by: 2) {
            mic.append(frames[i])
            system.append(frames[i + 1])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-\(UUID().uuidString).wav")
        let writer = try MeetingRecordingWriter(url: url)
        try writer.append(mic: mic, system: system)
        try writer.finish()
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = try MeetingRecordingWriter.parseWAVLayout(from: url)
        #expect(layout == MeetingRecordingWriter.WAVLayout(dataOffset: 44, dataByteCount: frames.count * 2))

        let channels = try MeetingRecordingWriter.readChannels(from: url)
        #expect(channels.mic == mic)
        #expect(channels.system == system)
    }

    @Test func listChunkBeforeDataKeepsChannelsAlignedAndOddSizePadded() throws {
        var listPayload = Array("INFOILabel".utf8)
        listPayload.append(contentsOf: Array("an odd-length ffmpeg comment".utf8))
        if listPayload.count % 2 == 0 { listPayload.append(0x21) }  // force odd size -> pad byte before data
        #expect(listPayload.count % 2 == 1)

        let url = try Self.write(
            Self.wav(pre: [Chunk(id: "LIST", payload: listPayload)], samples: Self.rampFrames(64)),
            name: "list-prefix")

        let channels = try MeetingRecordingWriter.readChannels(from: url)
        #expect(channels.mic.first == Int16(1_000), "left (mic) must read from the real data chunk, not from inside LIST")
        #expect(channels.system.first == Int16(-30_000), "right (system) must sit beside left, not swapped into it")
        #expect(channels.mic.last == Int16(1_063))
        #expect(channels.system.last == Int16(-30_063))
    }

    @Test func chunksAfterDataAreNotReadAsFrames() throws {
        let url = try Self.write(
            Self.wav(post: [Chunk(id: "LIST", payload: Array(repeating: 0x41, count: 33))], samples: Self.rampFrames(64)),
            name: "list-postfix")

        let channels = try MeetingRecordingWriter.readChannels(from: url)
        #expect(channels.mic.count == 64, "trailing chunks must not become garbage frames")
        #expect(channels.system.count == 64)

        let reader = try #require(MeetingRecordingWriter.ChannelReader(url: url))
        var total = 0
        while let block = reader.nextBlock(frameCount: 16) { total += block.mic.count }
        reader.close()
        #expect(total == 64, "ChannelReader must stop at the data chunk's end")
    }

    @Test func channelReaderSkipsPrefixAndPostfixChunks() throws {
        var listPayload = Array("INFOICMT".utf8)
        listPayload.append(0x21)  // odd size -> pad byte before data
        let url = try Self.write(
            Self.wav(
                pre: [Chunk(id: "LIST", payload: listPayload)],
                post: [Chunk(id: "cue ", payload: [0, 0, 0, 0, 0])],
                samples: Self.rampFrames(40)),
            name: "reader-both")

        let reader = try #require(MeetingRecordingWriter.ChannelReader(url: url))
        let first = reader.nextBlock(frameCount: 100)
        reader.close()
        let block = try #require(first)
        #expect(block.mic == (0..<40).map { Int16(clamping: 1000 + $0) })
        #expect(block.system == (0..<40).map { Int16(clamping: -30_000 - $0) })
    }

    @Test func nonRIFFFileIsRejectedNamingWhatWasFound() throws {
        let url = try Self.write(Data([0x49, 0x44, 0x33, 0x03]) + Data(repeating: 0, count: 64), name: "id3")
        #expect(throws: MeetingRecordingWriterError.notWaveFile(found: "leading bytes \"ID3\u{03}\"")) {
            try MeetingRecordingWriter.readChannels(from: url)
        }
    }

    @Test func monoWavIsRejectedNamingTheFormat() throws {
        var body = Data()
        body.append(contentsOf: Array("fmt ".utf8))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(16)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(1)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(1)))  // mono
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(16000)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(32000)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(2)))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt16(16)))
        body.append(contentsOf: Array("data".utf8))
        body.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(4)))
        body.append(contentsOf: [1, 0, 2, 0])

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: MeetingAudioCapture.leBytes(UInt32(4 + body.count)))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: body)

        let url = try Self.write(wav, name: "mono")
        #expect(throws: MeetingRecordingWriterError.unsupportedFormat(found: "format code 1, 16-bit, 1-channel")) {
            try MeetingRecordingWriter.readChannels(from: url)
        }
    }

    // MARK: - Real meeting fixture (env MEETING_WAV)

    /// The NTT meeting recording: left (mic) was silent in the room, right (system) carries the
    /// whole in-room conversation - so after the fix the mic channel must be the SILENT one. The
    /// old 44-byte-hardcoded reader on a chunk-prefixed file produced the opposite (channels
    /// swapped + shifted), which is exactly what this pins down.
    @Test func meetingFixtureKeepsMicSilentAndSystemLoudWithMultipleVADRegions() throws {
        guard let path = ProcessInfo.processInfo.environment["MEETING_WAV"],
            FileManager.default.fileExists(atPath: path)
        else {
            print("MeetingWAVReaderTests: MEETING_WAV not set, skipping fixture test")
            try? "MEETING_WAV=\(ProcessInfo.processInfo.environment["MEETING_WAV"] ?? "nil")"
                .write(toFile: "/tmp/vi-fixture-skip.txt", atomically: true, encoding: .utf8)
            return
        }
        let url = URL(fileURLWithPath: path)

        let layout = try MeetingRecordingWriter.parseWAVLayout(from: url)
        let channels = try MeetingRecordingWriter.readChannels(from: url)
        print(
            "fixture layout: dataOffset=\(layout.dataOffset) dataBytes=\(layout.dataByteCount) frames=\(channels.mic.count)")
        #expect(layout.dataByteCount % 4 == 0)
        #expect(channels.mic.count == layout.dataByteCount / 4)

        let micRMS = MeetingVAD.rms(channels.mic[...])
        let systemRMS = MeetingVAD.rms(channels.system[...])
        print("fixture RMS: mic=\(micRMS) system=\(systemRMS)")
        #expect(micRMS < MeetingVAD.absoluteFloor, "left (mic) must stay the silent channel - if this fails the channels are swapped")
        #expect(systemRMS > 10 * max(micRMS, 1), "right (system) must carry the in-room speech energy")

        let regions = MeetingVAD.regions(for: channels.system)
        print("fixture system-channel VAD regions: \(regions.count)")
        #expect(regions.count >= 3, "the in-room conversation must yield multiple speech regions")

        let micRegions = MeetingVAD.regions(for: channels.mic)
        #expect(micRegions.isEmpty, "the silent mic channel must yield no speech regions at all")
    }

    // MARK: - Full end-to-end transcript (env MEETING_FULL=1, env MEETING_WAV, env MEETING_OUT)

    /// The deliverable check: the exact production path `AudioTranscriptionService.retranscribeMeetingAudio`
    /// runs (`MeetingRecordingTranscriber` -> `MeetingTurnTranscriber` -> `MeetingSpeakerIdentifier`
    /// -> `MeetingSpeakerTranscriptRenderer`), writing the complete speaker-labelled transcript to
    /// `MEETING_OUT`. Minutes of real ASR - run with its own long timeout, not the 60 s cap.
    @Test func fullMeetingTranscriptRendersSpeakerLabelledText() async throws {
        let env = ProcessInfo.processInfo.environment
        try? "full test started; MEETING_FULL=\(env["MEETING_FULL"] ?? "nil") MEETING_WAV=\(env["MEETING_WAV"] ?? "nil") MEETING_OUT=\(env["MEETING_OUT"] ?? "nil")"
            .write(toFile: "/tmp/vi-full-trace.txt", atomically: true, encoding: .utf8)
        guard env["MEETING_FULL"] == "1",
            let path = env["MEETING_WAV"],
            FileManager.default.fileExists(atPath: path)
        else {
            print("MeetingWAVReaderTests: MEETING_FULL not set, skipping full transcript test")
            try? "MEETING_FULL=\(env["MEETING_FULL"] ?? "nil") MEETING_WAV=\(env["MEETING_WAV"] ?? "nil")"
                .write(toFile: "/tmp/vi-full-skip.txt", atomically: true, encoding: .utf8)
            return
        }

        func trace(_ s: String) {
            print(s)
            let old = (try? String(contentsOfFile: "/tmp/vi-full-trace.txt", encoding: .utf8)) ?? ""
            try? (old + s + "\n").write(toFile: "/tmp/vi-full-trace.txt", atomically: true, encoding: .utf8)
        }

        let url = URL(fileURLWithPath: path)
        let channels = try MeetingRecordingWriter.readChannels(from: url)
        trace("channels read: \(channels.mic.count) frames")

        let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("WhisperModels", isDirectory: true)
        let provider = WhisperModelManager(modelsDirectory: modelsDirectory)
        provider.loadAvailableModels()
        trace(
            "models dir \(modelsDirectory.path): \(provider.availableModels.map(\.name)) exists=\(FileManager.default.fileExists(atPath: modelsDirectory.path))")
        guard let modelFile = provider.availableModels.first else {
            print("MeetingWAVReaderTests: no downloaded whisper model, skipping full transcript test")
            trace("SKIP: no downloaded whisper model")
            return
        }
        let model = WhisperModel(
            name: modelFile.name, displayName: modelFile.name, size: "",
            supportedLanguages: ["de": "German", "en": "English"], description: "", speed: 0, accuracy: 0, ramUsage: 0)

        let registry = TranscriptionServiceRegistry(
            modelProvider: provider, modelsDirectory: modelsDirectory,
            modelContext: ModelContext(
                try ModelContainer(for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))))

        // Same fallback the retranscribe path uses when there is no live session: the offline
        // diarization profile, plain "[Others:]" labels when the model is unavailable.
        let diarizer = await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.offlineConfig)
        print("diarizer available: \(diarizer != nil)")
        trace("diarizer available: \(diarizer != nil)")

        let turns = await MeetingRecordingTranscriber.transcribe(
            stereoURL: url, model: model, requestContext: .currentDefaults.scoped(to: model),
            serviceRegistry: registry, existingDiarizer: diarizer)
        print("transcribed turns: \(turns.count), non-empty: \(turns.filter { !$0.text.isEmpty }.count)")
        trace("transcribed turns: \(turns.count), non-empty: \(turns.filter { !$0.text.isEmpty }.count)")

        let labelled = await MeetingSpeakerIdentifier.assignSpeakers(
            to: turns, systemChannel: channels.system, micChannel: channels.mic,
            meetingID: UUID(), library: SpeakerLibraryStore.shared)
        let transcript = MeetingSpeakerTranscriptRenderer.render(labelled) { SpeakerLibraryStore.shared.name(for: $0) }

        let speakers = Set(labelled.compactMap(\.speakerID))
        print("distinct speaker ids: \(speakers.count) \(speakers.sorted())")
        print("transcript chars: \(transcript.count)")
        trace("labelled: \(labelled.count), speakers: \(speakers.count), transcript chars: \(transcript.count)")

        let outPath = ProcessInfo.processInfo.environment["MEETING_OUT"] ?? "/tmp/vi-meeting-transcript.txt"
        try transcript.write(toFile: outPath, atomically: true, encoding: .utf8)
        try """
            turns: \(turns.count) (non-empty \(turns.filter { !$0.text.isEmpty }.count))
            speakers: \(speakers.count) \(speakers.sorted())
            diarizer: \(diarizer != nil)
            model: \(modelFile.name)
            """
            .write(toFile: outPath + ".report", atomically: true, encoding: .utf8)

        #expect(!labelled.isEmpty, "the meeting must produce turns")
        #expect(!transcript.isEmpty, "the meeting must produce a transcript")
    }
}
