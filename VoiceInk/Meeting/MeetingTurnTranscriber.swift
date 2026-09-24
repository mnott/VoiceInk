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
    ///   - systemDiarization: This chunk/super-block's diarized speaker segments (see
    ///     `MeetingDiarizer`/`MeetingDiarizationAttributor`), or `nil` when speaker identification
    ///     isn't running this session - the pre-diarization behaviour, plain VAD on `system`
    ///     labelled with the single generic "Others". When non-nil, `system`'s own VAD regions -
    ///     unchanged from the pre-diarization behaviour, so nothing VAD hears is ever dropped just
    ///     because the diarizer didn't cover it - are labelled by diarizer overlap instead (see
    ///     `MeetingDiarizationLabeler`).
    ///   - micDiarization: Same idea as `systemDiarization` but for the mic channel, in an
    ///     in-person meeting (see `MeetingCaptureModeDetector`) - splits `mic` into `.otherMic`
    ///     speakers instead of the pre-in-person "whole channel is `.me`" behaviour. `nil` (the
    ///     default) keeps that pre-in-person behaviour.
    /// - Returns: The transcribed turns, plus the noise floor each channel ended on - so a caller
    ///   stitching several calls together over one file/session can seed the next one with it
    ///   instead of starting over at 0 (see
    ///   `MeetingVAD.regionsAndEndingNoiseFloor(for:startingNoiseFloor:)`).
    static func transcribe(
        mic: [Int16], system: [Int16],
        model: any TranscriptionModel, requestContext: TranscriptionRequestContext,
        serviceRegistry: TranscriptionServiceRegistry,
        micNoiseFloor: Double = 0, systemNoiseFloor: Double = 0,
        systemDiarization: MeetingAudioCapture.SystemDiarization? = nil,
        micDiarization: MeetingAudioCapture.MicDiarization? = nil
    ) async -> (turns: [MeetingTurnTranscriptRenderer.TranscribedTurn], micNoiseFloor: Double, systemNoiseFloor: Double) {
        let (meRegions, meSpeakers, endingMicNoiseFloor) = Self.diarizedRegionsAndSpeakers(
            channel: mic, noiseFloor: micNoiseFloor, diarization: micDiarization,
            speakerForSlot: { .otherMic($0) }, uncommittedTailSpeaker: .othersMic)
        let (othersRegions, othersSpeakers, endingSystemNoiseFloor) = Self.diarizedRegionsAndSpeakers(
            channel: system, noiseFloor: systemNoiseFloor, diarization: systemDiarization,
            speakerForSlot: { .other($0) }, uncommittedTailSpeaker: .others)
        let builtTurns = MeetingTurnBuilder.build(
            meRegions: meRegions, othersRegions: othersRegions, meSamples: mic, othersSamples: system,
            meSpeakers: meSpeakers, othersSpeakers: othersSpeakers)
        // Re-joins same-speaker turns `build()`'s own length cap split apart, purely for this
        // clip-per-turn transcription loop - see `mergeAdjacentSameSpeakerForTranscription`'s doc
        // comment for why the split itself stays untouched.
        let turns = MeetingTurnBuilder.mergeAdjacentSameSpeakerForTranscription(builtTurns)

        var results: [MeetingTurnTranscriptRenderer.TranscribedTurn] = []
        // Serial, not concurrent: the local Whisper model is not safe to run two transcriptions
        // at once.
        for turn in turns {
            let source = turn.speaker.isMicChannel ? mic : system
            guard turn.start < turn.end, turn.end <= source.count else { continue }

            let clip = MeetingAudioCapture.padded(
                Array(source[turn.start..<turn.end]), paddingSamples: MeetingTurnBuilder.transcriptionPaddingSamples)
            let text = await transcribedText(
                for: clip, model: model, requestContext: requestContext, serviceRegistry: serviceRegistry)
            let filtered = TranscriptionOutputFilter.filter(text).trimmingCharacters(in: .whitespacesAndNewlines)
            // Drops punctuation-only interjections ("-", "...") that VAD/diarization still turn
            // into a labelled turn but that carry no actual words.
            guard filtered.rangeOfCharacter(from: .alphanumerics) != nil else { continue }

            results.append(.init(speaker: turn.speaker, text: filtered, start: turn.start, end: turn.end))
        }
        return (MeetingEchoSafetyNet.filter(results), endingMicNoiseFloor, endingSystemNoiseFloor)
    }

    /// Builds `MeetingTurnBuilder.build`'s `meRegions`/`meSpeakers` or `othersRegions`/
    /// `othersSpeakers` pair for one channel: `channel`'s own VAD regions always decide WHAT gets
    /// transcribed; the diarizer (when running) only decides WHO, via `MeetingDiarizationLabeler`.
    private static func diarizedRegionsAndSpeakers(
        channel: [Int16], noiseFloor: Double, diarization: MeetingDiarizationAttributor.Attribution?,
        speakerForSlot: (Int) -> MeetingTurnBuilder.Speaker, uncommittedTailSpeaker: MeetingTurnBuilder.Speaker
    ) -> (regions: [MeetingVAD.Region], speakers: [MeetingTurnBuilder.Speaker]?, endingNoiseFloor: Double) {
        let (vadRegions, floor) = MeetingVAD.regionsAndEndingNoiseFloor(for: channel, startingNoiseFloor: noiseFloor)
        guard let diarization else {
            return (vadRegions, nil, floor)
        }
        let (regions, speakers) = MeetingDiarizationLabeler.label(
            vadRegions: vadRegions, diarizedSegments: diarization.regions, samples: channel,
            speakerForSlot: speakerForSlot, noSpeaker: uncommittedTailSpeaker)
        return (regions, speakers, floor)
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
