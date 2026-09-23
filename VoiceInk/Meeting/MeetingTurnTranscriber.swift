import Foundation

/// Runs VAD + turn building on a self-contained stereo buffer (a chunk-hotkey cut, or one
/// silence-bounded super-block of a longer recording) and transcribes each turn serially from
/// its own channel, returning the non-empty results in turn order, after `MeetingEchoSafetyNet`
/// strips any residual acoustic echo the words themselves still show. Shared by per-chunk delivery
/// (`VoiceInkEngine+Meeting`) and the whole-meeting transcript (`MeetingRecordingTranscriber`) so
/// both get the same speaker-ordering and echo-safety treatment instead of one being windowed and
/// the other not.
enum MeetingTurnTranscriber {
    /// - Parameters:
    ///   - micNoiseFloor: Seeds the mic channel's VAD noise floor instead of starting from 0 - see
    ///     `MeetingVAD.regions(for:startingNoiseFloor:)`. Defaults to 0 (the previous behaviour)
    ///     for the whole-meeting transcript's (`MeetingRecordingTranscriber`) first super-block;
    ///     later super-blocks seed from the ending floor this function returns.
    ///   - systemNoiseFloor: Same, for the system-audio channel.
    /// - Returns: The transcribed turns, plus the noise floor each channel ended on - so a caller
    ///   stitching several calls together over one file/session can seed the next one with it
    ///   instead of starting over at 0 (see
    ///   `MeetingVAD.regionsAndEndingNoiseFloor(for:startingNoiseFloor:)`).
    static func transcribe(
        mic: [Int16], system: [Int16],
        model: any TranscriptionModel, requestContext: TranscriptionRequestContext,
        serviceRegistry: TranscriptionServiceRegistry,
        micNoiseFloor: Double = 0, systemNoiseFloor: Double = 0
    ) async -> (turns: [MeetingTurnTranscriptRenderer.TranscribedTurn], micNoiseFloor: Double, systemNoiseFloor: Double) {
        let (meRegions, endingMicNoiseFloor) = MeetingVAD.regionsAndEndingNoiseFloor(for: mic, startingNoiseFloor: micNoiseFloor)
        let (othersRegions, endingSystemNoiseFloor) = MeetingVAD.regionsAndEndingNoiseFloor(for: system, startingNoiseFloor: systemNoiseFloor)
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

            results.append(.init(speaker: turn.speaker, text: filtered, start: turn.start, end: turn.end))
        }
        return (MeetingEchoSafetyNet.filter(results), endingMicNoiseFloor, endingSystemNoiseFloor)
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
