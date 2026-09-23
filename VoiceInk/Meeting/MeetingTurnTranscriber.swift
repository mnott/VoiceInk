import Foundation

/// Runs VAD + turn building on a self-contained stereo buffer (a chunk-hotkey cut, or one
/// silence-bounded super-block of a longer recording) and transcribes each turn serially from
/// its own channel, returning the non-empty results in turn order. Shared by per-chunk delivery
/// (`VoiceInkEngine+Meeting`) and the whole-meeting transcript (`MeetingRecordingTranscriber`) so
/// both get the same speaker-ordering treatment instead of one being windowed and the other not.
enum MeetingTurnTranscriber {
    /// - Parameters:
    ///   - micNoiseFloor: Seeds the mic channel's VAD noise floor instead of starting from 0 - see
    ///     `MeetingVAD.regions(for:startingNoiseFloor:)`. Defaults to 0 (the previous behaviour)
    ///     for the whole-meeting transcript (`MeetingRecordingTranscriber`), whose super-blocks
    ///     always start in genuine silence and so need no seed.
    ///   - systemNoiseFloor: Same, for the system-audio channel.
    static func transcribe(
        mic: [Int16], system: [Int16],
        model: any TranscriptionModel, requestContext: TranscriptionRequestContext,
        serviceRegistry: TranscriptionServiceRegistry,
        micNoiseFloor: Double = 0, systemNoiseFloor: Double = 0
    ) async -> [MeetingTurnTranscriptRenderer.TranscribedTurn] {
        let meRegions = MeetingVAD.regions(for: mic, startingNoiseFloor: micNoiseFloor)
        let othersRegions = MeetingVAD.regions(for: system, startingNoiseFloor: systemNoiseFloor)
        let turns = MeetingTurnBuilder.build(
            meRegions: meRegions, othersRegions: othersRegions, meSamples: mic, othersSamples: system)

        var results: [MeetingTurnTranscriptRenderer.TranscribedTurn] = []
        // Serial, not concurrent: the local Whisper model is not safe to run two transcriptions
        // at once.
        for turn in turns {
            let source = turn.speaker == .me ? mic : system
            guard turn.start < turn.end, turn.end <= source.count else { continue }

            let clip = MeetingAudioCapture.padded(
                Array(source[turn.start..<turn.end]), paddingSamples: MeetingTurnBuilder.transcriptionPaddingSamples)
            let text = await transcribedText(
                for: clip, model: model, requestContext: requestContext, serviceRegistry: serviceRegistry)
            let filtered = TranscriptionOutputFilter.filter(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filtered.isEmpty else { continue }

            results.append(.init(speaker: turn.speaker, text: filtered))
        }
        return results
    }

    private static func transcribedText(
        for samples: [Int16],
        model: any TranscriptionModel, requestContext: TranscriptionRequestContext,
        serviceRegistry: TranscriptionServiceRegistry
    ) async -> String {
        let trackURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: trackURL) }

        do {
            try MeetingAudioCapture.writeWAV(samples, to: trackURL)
            return try await serviceRegistry.transcribe(audioURL: trackURL, model: model, context: requestContext)
        } catch {
            return ""
        }
    }
}
