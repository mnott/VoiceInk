import Foundation

/// Turns a whole-meeting stereo recording (`MeetingRecordingWriter`'s output) into a turn-ordered,
/// speaker-labelled transcript. Used both right after `toggleMeetingCapture()` stops and by
/// re-transcription from History, so a meeting record always gets the same two-channel treatment
/// instead of a downmix.
///
/// Reads the file in small blocks and accumulates them into a super-block only cut where both
/// channels are currently silent (never mid-utterance, so a turn or an interjection never spans
/// two super-blocks); `MeetingTurnTranscriber` then runs on each super-block exactly as it does
/// on a chunk-hotkey cut. This bounds memory to a few minutes of audio at a time instead of
/// holding a whole (possibly hour-long) meeting in memory at once.
enum MeetingRecordingTranscriber {
    private static let sampleRate = MeetingVAD.sampleRate
    private static let readBlockFrames = Int(2 * sampleRate)
    private static let minSuperBlockFrames = Int(120 * sampleRate)
    // ponytail: a hard ceiling so continuous, pause-free speech still bounds memory - the rare
    // super-block cut this forces can split a turn mid-speech; raise if that shows up in practice.
    private static let maxSuperBlockFrames = Int(300 * sampleRate)
    // Comfortably above MeetingTurnBuilder's 2 s interjection tolerance and MeetingVAD's 500 ms
    // hangover, so a cut here can never land inside an in-progress region or interjection.
    private static let mutualSilenceTailFrames = Int(3 * sampleRate)

    /// Transcribes the whole recording and returns its turns as meeting-global-sample-offset
    /// `MeetingTurnRecord`s (diarized slot set where diarization ran, `speakerID` always `nil` -
    /// see `MeetingSpeakerIdentifier` for that step). Callers render `text` themselves via
    /// `MeetingSpeakerTranscriptRenderer` once speaker identification has run.
    ///
    /// - Parameters:
    ///   - existingDiarizer: The live session's own (already-finished) system-channel diarizer,
    ///     when this is the note written right after `toggleMeetingCapture()` stops - reused
    ///     instead of a second offline-profile pass over the same audio, since the session already
    ///     ran the streaming profile continuously over the whole system channel in the same global
    ///     sample coordinates as this recording (`MeetingAudioCapture.absorbAndWrite` appends the
    ///     identical `system` samples, in the identical order, to both). `nil` for History
    ///     re-transcribe / an imported meeting file, which has no live session to reuse and falls
    ///     back to a fresh offline-profile pass, per this file's proof
    ///     (`MeetingDiarizationOfflineProofTests`) showing it labels at least as well as streaming.
    ///   - existingMicDiarizer: Same idea as `existingDiarizer` but for the mic channel, when the
    ///     live session ran in-person mode (see `MeetingCaptureMode`). `nil` otherwise.
    static func transcribe(
        stereoURL: URL,
        model: any TranscriptionModel,
        requestContext: TranscriptionRequestContext,
        serviceRegistry: TranscriptionServiceRegistry,
        existingDiarizer: MeetingDiarizer? = nil,
        existingMicDiarizer: MeetingDiarizer? = nil
    ) async -> [MeetingTurnRecord] {
        guard let reader = MeetingRecordingWriter.ChannelReader(url: stereoURL) else { return [] }
        defer { reader.close() }

        let diarizer: MeetingDiarizer?
        if let existingDiarizer {
            // Already fed every sample live and `finish()`ed by `MeetingAudioCapture.stop()` -
            // further `append`/`finish` calls below are no-ops (see `MeetingDiarizer.append`'s
            // guard). Only the attribution watermark needs resetting, since the live session's
            // own per-chunk delivery already advanced it through the whole recording.
            existingDiarizer.resetAttributionWatermark()
            diarizer = existingDiarizer
        } else {
            // One continuous offline-profile session for the whole recording (see `MeetingDiarizer`'s
            // doc comment) - `nil` (silent fallback to the single "Others" label) unless the setting
            // is on and the model is downloaded; never triggers a download itself.
            diarizer =
                UserDefaults.standard.bool(forKey: PinnedDestinationSettingsKeys.identifyRemoteSpeakers)
                ? await MeetingDiarizer.makeIfAvailable(config: MeetingDiarizationModels.offlineConfig)
                : nil
        }

        let micDiarizer: MeetingDiarizer?
        if let existingMicDiarizer {
            existingMicDiarizer.resetAttributionWatermark()
            micDiarizer = existingMicDiarizer
        } else {
            micDiarizer = nil
        }

        var allTurns: [MeetingTurnRecord] = []
        var micAcc: [Int16] = []
        var systemAcc: [Int16] = []
        // 0 until the first super-block establishes it - later super-blocks seed from it instead of
        // starting over at 0, since only the very first one is guaranteed to start in genuine silence.
        var micNoiseFloor: Double = 0
        var systemNoiseFloor: Double = 0
        var systemGlobalOffset = 0

        // `alreadyAppended` lets the final call below hand its trailing audio to the diarizer
        // itself, ahead of `finish()`, without this appending it a second time.
        func flush(alreadyAppended: Bool = false) async {
            guard !micAcc.isEmpty else { return }

            var diarization: MeetingAudioCapture.SystemDiarization? = nil
            if let diarizer {
                if !alreadyAppended {
                    diarizer.append(systemAcc)
                }
                diarization = diarizer.attribute(
                    chunkStartGlobal: systemGlobalOffset, chunkEndGlobal: systemGlobalOffset + systemAcc.count)
            }
            var micDiarization: MeetingAudioCapture.MicDiarization? = nil
            if let micDiarizer {
                if !alreadyAppended {
                    micDiarizer.append(micAcc)
                }
                // Mic and system are read in lockstep (see below), so `systemGlobalOffset` is this
                // super-block's start in either channel's own global sample coordinates.
                micDiarization = micDiarizer.attribute(
                    chunkStartGlobal: systemGlobalOffset, chunkEndGlobal: systemGlobalOffset + micAcc.count)
            }

            let result = await MeetingTurnTranscriber.transcribe(
                mic: micAcc, system: systemAcc, model: model, requestContext: requestContext,
                serviceRegistry: serviceRegistry, micNoiseFloor: micNoiseFloor, systemNoiseFloor: systemNoiseFloor,
                systemDiarization: diarization, micDiarization: micDiarization)
            // Mic and system are read in lockstep from the same stereo file, so one running offset
            // (this super-block's start, in samples since the meeting began) applies to both
            // channels' turns - see `MeetingTurnRecord.init(_:globalOffset:)`.
            allTurns.append(contentsOf: result.turns.map { MeetingTurnRecord($0, globalOffset: systemGlobalOffset) })
            micNoiseFloor = result.micNoiseFloor
            systemNoiseFloor = result.systemNoiseFloor
            systemGlobalOffset += systemAcc.count
            micAcc.removeAll()
            systemAcc.removeAll()
        }

        while let block = reader.nextBlock(frameCount: readBlockFrames) {
            micAcc.append(contentsOf: block.mic)
            systemAcc.append(contentsOf: block.system)

            let readyToCut = micAcc.count >= minSuperBlockFrames && bothChannelsSilentAtTail(mic: micAcc, system: systemAcc)
            if micAcc.count >= maxSuperBlockFrames || readyToCut {
                await flush()
            }
        }
        // The last super-block's audio must reach the diarizer (`append`) before `finish()` -
        // `Nemotron3Diarizer.appendAudio` traps once the stream is finished. `finish()` then
        // flushes the trailing partial chunk so the final `flush()`'s `attribute()` call (which
        // must skip re-appending what was just appended here) sees it, instead of losing the
        // whole recording's last few seconds of "Others" speech.
        if let diarizer, !systemAcc.isEmpty {
            diarizer.append(systemAcc)
        }
        if let micDiarizer, !micAcc.isEmpty {
            micDiarizer.append(micAcc)
        }
        diarizer?.finish()
        micDiarizer?.finish()
        await flush(alreadyAppended: true)

        return allTurns
    }

    private static func bothChannelsSilentAtTail(mic: [Int16], system: [Int16]) -> Bool {
        guard mic.count >= mutualSilenceTailFrames else { return false }
        let micTail = mic.suffix(mutualSilenceTailFrames)
        let systemTail = system.suffix(mutualSilenceTailFrames)
        return MeetingVAD.rms(micTail) < MeetingVAD.absoluteFloor && MeetingVAD.rms(systemTail) < MeetingVAD.absoluteFloor
    }
}
