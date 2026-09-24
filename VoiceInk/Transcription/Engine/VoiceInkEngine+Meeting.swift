import Foundation
import os

/// A meeting audio stream is not a single-shot recording: it keeps capturing after each hotkey
/// press so the call is never interrupted, and each press transcribes and delivers only the
/// audio captured since the previous one. This is why it bypasses `toggleRecord`/`runPipeline`
/// (a single-shot record -> stop -> one file state machine) and talks to `pipeline` directly.
///
/// Two different History behaviors live side by side here: per-chunk deliveries are paste-only
/// and never touch History (`saveToHistory: false` below - see `TranscriptionPipeline.run`'s doc
/// comment), while the *whole* meeting (Toggle Meeting Capture start to stop) becomes exactly one
/// History record, built directly in `transcribeAndSaveMeetingRecording` once capture stops.
@MainActor
extension VoiceInkEngine {
    // Same subsystem/category as `MeetingAudioCapture`'s own logger - this is diagnosing the same
    // auto-send pipeline, just from the delivery side of `cut()` rather than the trigger side.
    private static let meetingLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingAudioCapture")

    private static let minimumChunkSampleCount = 8_000  // 0.5s at 16kHz mono
    // Below this, an empty-transcript meeting recording is discarded outright rather than kept
    // as a placeholder History record - not worth cluttering History over a few seconds of dead
    // air after starting and immediately stopping capture.
    private static let minimumMeaningfulMeetingDurationSeconds: TimeInterval = 3

    func toggleMeetingCapture() async {
        // Blocks re-entry for the whole stop branch below, not just a flag read/write race: a
        // toggle pressed again while e.g. `await capture.cut()` or `await meetingChunkTask?.value`
        // is in flight must not start a new session, or that new session's `currentMeetingID`/
        // trackers would be live while this stop is still reading/resetting them for the old one -
        // see `isMeetingCaptureStopping`'s doc comment.
        guard !isMeetingCaptureStopping else {
            Self.meetingLogger.notice("Meeting capture: toggle ignored while previous session is stopping")
            return
        }
        if isMeetingCaptureActive {
            isMeetingCaptureStopping = true
            defer { isMeetingCaptureStopping = false }
            let capture = meetingCapture
            isMeetingCaptureActive = false
            meetingCapture = nil

            // An automatic or manual cut may already be in flight (triggered just before this
            // toggle) - its own `cut()`/`cutForManualSend()`/`deliverMeetingChunk` must finish
            // first: two concurrent cuts on the same capture race each other's diarizer-commit
            // wait, so that chunk's `deliverMeetingChunk` call (and hence its place in
            // `meetingChunkTask`'s delivery order) can otherwise land after this stop's own final
            // chunk instead of before it, and `capture.stop()` below would tear the diarizer down
            // while it is still attributing against it.
            let pendingCut = pendingCutTask
            pendingCutTask = nil
            await pendingCut?.value

            if let capture {
                let cut = await capture.cut(forceFullRelease: true)
                deliverMeetingChunk(
                    cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: false,
                    isAutomatic: false)
            }
            let sessionRecordingURL = capture?.recordingURL
            let sessionStartedAt = capture?.startedAt
            let wasInPersonWithNoMeVoice =
                capture?.captureMode == .inPerson && !SpeakerLibraryStore.shared.voices.contains { $0.isMe }
            capture?.stop()
            // Read after `stop()` returns, so `finish()` (called synchronously inside it) has
            // already flushed each diarizer's trailing partial chunk - see
            // `MeetingAudioCapture.finishedSystemDiarizer`'s doc comment.
            let sessionDiarizer = capture?.finishedSystemDiarizer()
            let sessionMicDiarizer = capture?.finishedMicDiarizer()
            // The session's own meeting id, not a fresh one: the live tracker already recorded
            // matches under this id (see `observeLiveSpeakers`), so the note must reuse it too, or
            // the same voice ends up with two different meetingIDs for one session.
            let sessionMeetingID = currentMeetingID ?? UUID()
            currentMeetingID = nil
            // Wait for the final chunk's own task (chained onto `meetingChunkTask` by
            // `deliverMeetingChunk` above) to finish rendering before reading the tracker below -
            // otherwise a slot first matched/registered while that chunk renders is missing from
            // the snapshot, and the last live chunk itself renders after `reset()` and falls back
            // to the generic "Others" label even though diarization/matching succeeded for it.
            await meetingChunkTask?.value
            // Snapshot after the await, not before: the final chunk's own matches (recorded by
            // `observeLiveSpeakers` while it renders, above) must make it into the note's id
            // mapping too, not just whatever matched before this stop was requested.
            let sessionIDBySlot = liveSpeakerTracker.state.sessionIDBySlot
            let micSessionIDBySlot = micSpeakerTracker.state.sessionIDBySlot
            // Safe to reset unconditionally: `isMeetingCaptureStopping` (set above) blocks any new
            // session from starting until this whole branch returns, so no newer session's state
            // can be live here to wipe.
            liveSpeakerTracker.reset()
            micSpeakerTracker.reset()

            if let sessionRecordingURL, let sessionStartedAt {
                enqueueMeetingRecordingTranscription(
                    recordingURL: sessionRecordingURL, startedAt: sessionStartedAt,
                    diarizer: sessionDiarizer, micDiarizer: sessionMicDiarizer,
                    sessionIDBySlot: sessionIDBySlot, micSessionIDBySlot: micSessionIDBySlot,
                    meetingID: sessionMeetingID)
            }

            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture stopped"),
                type: .info
            )

            showMissingMeVoiceHintIfNeeded(wasInPersonWithNoMeVoice: wasInPersonWithNoMeVoice)
        } else {
            let recordingURL = recordingsDirectory.appendingPathComponent("meeting-\(UUID().uuidString).wav")
            let capture = MeetingAudioCapture(recordingURL: recordingURL)
            capture.onAutoSendTrigger = { [weak self] in
                Task { @MainActor in
                    self?.beginAutoSendChunk()
                }
            }
            capture.start()
            // A dictation already in flight when a meeting capture starts mid-recording must
            // still be excluded - `recordingState`'s `didSet` only fires on later transitions.
            capture.isDictationActive = Self.isDictationRecordingState(recordingState)
            meetingCapture = capture
            isMeetingCaptureActive = true
            currentMeetingID = UUID()
            liveSpeakerTracker.reset()
            micSpeakerTracker.reset()

            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture started"),
                type: .info
            )

            if !capture.isCapturingSystemAudio {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Recording microphone only - allow System Audio Recording for VoiceInk"),
                    type: .warning
                )
            }

            if MeetingLidSleepRisk.warrantsWarning(
                isOnBattery: MeetingPowerState.isOnBattery(), hasExternalDisplay: MeetingPowerState.hasExternalDisplay())
            {
                NotificationManager.shared.showNotification(
                    title: String(localized: "On battery with no external display - closing the lid will stop this recording"),
                    type: .warning
                )
            }
        }
    }

    /// One-time nudge (see `PinnedDestinationSettingsKeys.hasShownMissingMeVoiceHint`) shown after
    /// an in-person meeting (see `MeetingCaptureModeDetector`) ends with no library voice flagged
    /// "this is me" - explaining why every mic speaker rendered by name/id instead of "[Me:]" (see
    /// `MeetingMicSpeakerMapper`'s "never assume" doc comment) and what to do about it.
    private func showMissingMeVoiceHintIfNeeded(wasInPersonWithNoMeVoice: Bool) {
        guard wasInPersonWithNoMeVoice,
            !UserDefaults.standard.bool(forKey: PinnedDestinationSettingsKeys.hasShownMissingMeVoiceHint)
        else { return }
        UserDefaults.standard.set(true, forKey: PinnedDestinationSettingsKeys.hasShownMissingMeVoiceHint)
        NotificationManager.shared.showNotification(
            title: String(
                localized:
                    "No voice is marked \"This is me\" yet - mark one in Settings \u{2192} Speakers so Meeting Capture can label you"
            ),
            type: .info, duration: 5.0
        )
    }

    /// Manual (hotkey) chunk send. Delays the cut (see `MeetingAudioCapture.cutForManualSend`) and
    /// forces full release, so the last word spoken right up to the key press - whose VAD region
    /// may not have closed yet - is never deferred to a later chunk the way an automatic cut's
    /// open-utterance check would defer it.
    ///
    /// Routed through `beginCutTask` (chained onto `pendingCutTask` before any suspension point,
    /// same as `beginAutoSendChunk`) rather than cutting directly, so a stop pressed while
    /// `cutForManualSend()` is still delaying/waiting can await this same task instead of racing
    /// its own final cut against this one - see `pendingCutTask`'s doc comment.
    func sendMeetingChunk() async {
        guard isMeetingCaptureActive, let capture = meetingCapture else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture is not running"),
                type: .info
            )
            return
        }
        let task = beginCutTask { [weak self] in
            let cut = await capture.cutForManualSend()
            self?.deliverMeetingChunk(
                cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: true,
                isAutomatic: false)
        }
        await task.value
    }

    /// Chains `work` onto `pendingCutTask` and stores the result back into it before any
    /// suspension point, so `toggleMeetingCapture`'s stop branch (which reads/clears that property
    /// on the main actor) can never observe a cut having been triggered without a task to await -
    /// see `pendingCutTask`'s doc comment. Shared by `sendMeetingChunk` and `beginAutoSendChunk` so
    /// no two cuts (auto or manual) on the same capture ever run concurrently.
    @discardableResult
    private func beginCutTask(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previousTask = pendingCutTask
        let task = Task {
            await previousTask?.value
            await work()
        }
        pendingCutTask = task
        return task
    }

    /// Kicks off `sendMeetingChunkAutomatically` via `beginCutTask` - see its doc comment.
    private func beginAutoSendChunk() {
        beginCutTask { [weak self] in
            await self?.sendMeetingChunkAutomatically()
        }
    }

    /// Called from `MeetingAudioCapture.onAutoSendTrigger` (see `MeetingAutoSendPolicy`) once a
    /// natural turn boundary is found. Goes through exactly the same delivery path as the manual
    /// hotkey - same labels, same pinned delivery, silent, no History record - just without the
    /// "nothing to send" notification a user press would show, and without forcing full release
    /// (an open utterance is deferred to the next chunk, same as any other automatic cut).
    func sendMeetingChunkAutomatically() async {
        guard isMeetingCaptureActive, let capture = meetingCapture else { return }
        let cut = await capture.cut()
        deliverMeetingChunk(
            cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: false,
            isAutomatic: true)
    }

    /// "This Is Silence" (menu bar item while Meeting Capture runs, or hotkey): measures the
    /// NEXT 2 s of ambience and pins it as each channel's VAD noise floor for the rest of the
    /// session - for loud, steady backgrounds (a train, a busy office) where the mic's pauses sit
    /// above the threshold the VAD can converge to on its own, so they'd never register as
    /// silence. A fresh session starts unpinned (see `MeetingVAD.State.pinnedNoiseFloor`).
    func calibrateMeetingSilence() {
        guard isMeetingCaptureActive, let capture = meetingCapture else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture is not running"),
                type: .info
            )
            return
        }
        capture.calibrateSilence {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "Silence calibrated"),
                    type: .info
                )
            }
        }
    }

    // MARK: - Live speaker tracking ("who is speaking" indicator, live library matching, "Name Speaker" hotkey)

    /// Records each turn's speaker for the "who is speaking" indicator, and - for diarized turns -
    /// hands their audio to the matching live tracker for background library matching
    /// (`MeetingLiveSpeakerTracker.observe`): `liveSpeakerTracker` for remote (system-channel)
    /// speakers, `micSpeakerTracker` for in-person (mic-channel) ones - see
    /// `MeetingTurnBuilder.Speaker.otherMic`. Before returning, bound-waits (see
    /// `MeetingLiveSpeakerTracker.awaitBoundedMatches`) on every slot in this chunk that has a match
    /// still in flight, so a fast embed lands in time to render this same chunk with a name/library
    /// id instead of a provisional one - never delaying delivery by more than that bound.
    /// The final chunk delivered by the stop branch of `toggleMeetingCapture` runs with
    /// `isMeetingCaptureActive` already `false` (cleared before `cut()`/`deliverMeetingChunk`) but
    /// `isMeetingCaptureStopping` still `true` for the whole branch, so it must still be observed -
    /// otherwise it never records turns/provisional ids and renders with the generic "Others"
    /// fallback even though diarization succeeded. `isMeetingCaptureStopping` blocks any new
    /// session from starting in the meantime, so this can't let a later session's chunk in early.
    static func shouldObserveLiveSpeakers(active: Bool, stopping: Bool) -> Bool { active || stopping }

    private func observeLiveSpeakers(in turns: [MeetingTurnTranscriptRenderer.TranscribedTurn], mic: [Int16], system: [Int16]) async {
        guard Self.shouldObserveLiveSpeakers(active: isMeetingCaptureActive, stopping: isMeetingCaptureStopping) else { return }
        let meetingID = currentMeetingID ?? UUID()
        var pendingSlots: [(tracker: MeetingLiveSpeakerTracker, slot: Int)] = []
        for turn in turns {
            switch turn.speaker {
            case .me:
                liveSpeakerTracker.recordTurn(.me)
            case .other(nil), .otherMic(nil):
                break
            case .other(let slot?):
                liveSpeakerTracker.recordTurn(.remote(slot: slot))
                guard turn.start < turn.end, turn.end <= system.count else { continue }
                liveSpeakerTracker.observe(slot: slot, samples: system[turn.start..<turn.end], meetingID: meetingID)
                pendingSlots.append((liveSpeakerTracker, slot))
            case .otherMic(let slot?):
                micSpeakerTracker.recordTurn(.remote(slot: slot))
                guard turn.start < turn.end, turn.end <= mic.count else { continue }
                micSpeakerTracker.observe(slot: slot, samples: mic[turn.start..<turn.end], meetingID: meetingID)
                pendingSlots.append((micSpeakerTracker, slot))
            }
        }
        let pendingTasks = pendingSlots.compactMap { $0.tracker.pendingMatchTask(forSlot: $0.slot) }
        await MeetingLiveSpeakerTracker.awaitBoundedMatches(pendingTasks)
    }

    /// "Name Speaker" hotkey action: names (or merges into an existing library voice called `name`)
    /// the most recently active remote speaker - see `MeetingLiveSpeakerTracker.nameSpeaker`. A
    /// no-op if capture isn't running or no remote speaker has had a turn yet.
    func nameCurrentMeetingSpeaker(_ name: String) async {
        guard isMeetingCaptureActive, let slot = liveSpeakerTracker.state.mostRecentRemoteSlot else { return }
        await liveSpeakerTracker.nameSpeaker(slot: slot, name: name, meetingID: currentMeetingID ?? UUID())
    }

    // MARK: - Per-chunk delivery (paste-only, never saved to History)

    private func deliverMeetingChunk(
        cut: MeetingAudioCapture.MeetingCut, isCapturingSystemAudio: Bool, notifyWhenEmpty: Bool, isAutomatic: Bool
    ) {
        Self.meetingLogger.info(
            "Meeting chunk delivery: delivered=\(cut.mix.count, privacy: .public) deferred=\(cut.deferredSampleCount, privacy: .public) automatic=\(isAutomatic, privacy: .public)"
        )

        guard cut.mix.count >= Self.minimumChunkSampleCount else {
            if notifyWhenEmpty {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Nothing new to send yet"),
                    type: .info
                )
            }
            return
        }

        // Chained after the previous chunk's task so transcriptions stay in order and the local
        // Whisper model, which is not safe to run concurrently, only ever transcribes one meeting
        // chunk (or the final meeting recording) at a time. Delivery itself is NOT part of this
        // chain (see `transcribeMeetingChunk` -> `meetingChunkDeliveryCoordinator.submit`), so a
        // chunk held by the typing guard never blocks the next chunk's transcription.
        let previousTask = meetingChunkTask
        meetingChunkTask = Task { [weak self] in
            await previousTask?.value
            await self?.transcribeMeetingChunk(cut: cut, isCapturingSystemAudio: isCapturingSystemAudio)
        }
    }

    /// Raw transcript of a single meeting track, or "" if the track is silent or transcription
    /// fails. Writes the track to a scratch WAV file, transcribes it directly through the
    /// service registry, and deletes the file - this is the pipeline's transcription step without
    /// its filtering/delivery, since that runs once on the combined text instead.
    private func transcribedText(
        for samples: [Int16], transcriptionConfiguration: TranscriptionRuntimeConfiguration
    ) async -> String {
        guard MeetingAudioCapture.rms(samples) >= MeetingAudioCapture.silenceRMSThreshold else { return "" }

        let trackURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: trackURL) }

        do {
            try MeetingAudioCapture.writeWAV(samples, to: trackURL)
            return try await serviceRegistry.transcribe(
                audioURL: trackURL,
                model: transcriptionConfiguration.model,
                context: transcriptionConfiguration.requestContext
            )
        } catch {
            logger.error("❌ Failed to transcribe meeting track: \(error, privacy: .public)")
            return ""
        }
    }

    /// One chunk's scratch audio file plus the transcription configuration it was transcribed
    /// with, carried from `transcribeMeetingChunk` through `meetingChunkDeliveryCoordinator` to
    /// `deliverMeetingChunkText` - see `MeetingChunkDeliveryCoordinator`'s `Payload` generic.
    struct MeetingChunkPayload {
        let audioURL: URL
        let transcriptionConfiguration: TranscriptionRuntimeConfiguration
    }

    /// Transcribes one meeting chunk, then hands the rendered text off to
    /// `meetingChunkDeliveryCoordinator`, which delivers it immediately or holds it (see
    /// `MeetingChunkDeliveryGuard`) while the user is typing into the destination. Only this
    /// transcription step is chained on `meetingChunkTask` - see `deliverMeetingChunk`'s doc
    /// comment for why delivery itself is not.
    private func transcribeMeetingChunk(
        cut: MeetingAudioCapture.MeetingCut, isCapturingSystemAudio: Bool
    ) async {
        // Scratch file only: a chunk is paste-only and never becomes a History record, so its
        // audio has no reason to live in the (permanent) recordings directory. Deleted once
        // `deliverMeetingChunkText` is done with it - which may be after a hold, not necessarily
        // right after this function returns, so it is NOT cleaned up here via `defer`.
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        do {
            try MeetingAudioCapture.writeWAV(cut.mix, to: audioURL)
        } catch {
            logger.error("❌ Failed to write meeting chunk audio: \(error, privacy: .public)")
            return
        }

        guard
            let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )
        else {
            try? FileManager.default.removeItem(at: audioURL)
            NotificationManager.shared.showNotification(
                title: String(localized: "No transcription model is selected"),
                type: .error,
                playSound: false
            )
            return
        }

        // A session with neither a system channel to order turns against nor mic diarization
        // running (see `MeetingCaptureMode`) has nothing to build turns from, so it keeps the
        // plain, unlabeled whole-track transcription it always had.
        let combinedText: String
        if isCapturingSystemAudio || cut.micDiarization != nil {
            let result = await MeetingTurnTranscriber.transcribe(
                mic: cut.mic, system: cut.system,
                model: transcriptionConfiguration.model, requestContext: transcriptionConfiguration.requestContext,
                serviceRegistry: serviceRegistry,
                micNoiseFloor: cut.micNoiseFloor, systemNoiseFloor: cut.systemNoiseFloor,
                systemDiarization: cut.systemDiarization, micDiarization: cut.micDiarization)
            await observeLiveSpeakers(in: result.turns, mic: cut.mic, system: cut.system)
            combinedText = MeetingTurnTranscriptRenderer.render(result.turns) { [liveSpeakerTracker, micSpeakerTracker] speaker in
                switch speaker {
                case .other(let slot?):
                    return liveSpeakerTracker.state.label(for: .remote(slot: slot))
                case .otherMic(let slot?):
                    return MeetingMicSpeakerMapper.label(
                        libraryID: micSpeakerTracker.state.libraryID(forSlot: slot),
                        isMeVoice: { SpeakerLibraryStore.shared.voice(for: $0)?.isMe == true },
                        fallback: micSpeakerTracker.state.label(for: .remote(slot: slot)))
                default:
                    return nil
                }
            }
        } else {
            let micText = await transcribedText(for: cut.mic, transcriptionConfiguration: transcriptionConfiguration)
            combinedText = MeetingTranscriptCombiner.combine(micText: micText, systemText: "", isCapturingSystemAudio: false)
        }

        // `meetingChunkDeliveryCoordinator.submit` discards `audioURL` itself (via `discard`) when
        // `combinedText` is empty - see its doc comment - so the two silent/failed tracks case
        // (previously delivered as an empty `pretranscribedText`, a no-op) is handled there.
        //
        // Sanitized here, right before the hand-off to delivery: this text is about to be pasted
        // into whatever destination is pinned, and is other people's speech, not the user's own -
        // see `MeetingChunkTextSanitizer`'s doc comment. The whole-meeting History record built in
        // `transcribeAndSaveMeetingRecording` renders its own text separately and is unaffected.
        meetingChunkDeliveryCoordinator.submit(
            text: MeetingChunkTextSanitizer.sanitize(combinedText),
            payload: MeetingChunkPayload(audioURL: audioURL, transcriptionConfiguration: transcriptionConfiguration)
        )
    }

    /// The delivery step `meetingChunkDeliveryCoordinator` calls once a chunk (or several merged
    /// together, held while the user was typing) is clear to go out. `text` is already
    /// transcribed and rendered - only formatting/word-replacement/enhancement/delivery runs here.
    func deliverMeetingChunkText(_ text: String, payload: MeetingChunkPayload) async {
        defer { try? FileManager.default.removeItem(at: payload.audioURL) }

        // Transient: never inserted into modelContext, never saved, never posted as a History
        // event - only `pipeline.run`'s filter/format/word-replacement/enhancement/delivery runs
        // on it. See `TranscriptionPipeline.run`'s `saveToHistory` doc comment.
        let transcription = makeRecordingTranscription(
            for: payload.audioURL,
            text: "",
            duration: 0,
            transcriptionStatus: .pending
        )

        await pipeline.run(
            transcription: transcription,
            audioURL: payload.audioURL,
            transcriptionConfiguration: payload.transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: nil,
            pretranscribedText: text,
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            onStateChange: { _ in },
            shouldCancel: { false },
            onCancel: {},
            onDismiss: {},
            assistant: .inactive,
            playsFeedbackSound: false,
            saveToHistory: false
        )
    }

    // MARK: - Whole-meeting History record (created once, at stop)

    private func enqueueMeetingRecordingTranscription(
        recordingURL: URL, startedAt: Date, diarizer: MeetingDiarizer?, micDiarizer: MeetingDiarizer?,
        sessionIDBySlot: [Int: String], micSessionIDBySlot: [Int: String], meetingID: UUID
    ) {
        let previousTask = meetingChunkTask
        meetingChunkTask = Task { [weak self] in
            await previousTask?.value
            await self?.transcribeAndSaveMeetingRecording(
                recordingURL: recordingURL, startedAt: startedAt, diarizer: diarizer, micDiarizer: micDiarizer,
                sessionIDBySlot: sessionIDBySlot, micSessionIDBySlot: micSessionIDBySlot, meetingID: meetingID)
        }
    }

    private func transcribeAndSaveMeetingRecording(
        recordingURL: URL, startedAt: Date, diarizer: MeetingDiarizer?, micDiarizer: MeetingDiarizer?,
        sessionIDBySlot: [Int: String], micSessionIDBySlot: [Int: String], meetingID: UUID
    ) async {
        guard
            let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )
        else {
            NotificationManager.shared.showNotification(
                title: String(localized: "No transcription model is selected"),
                type: .error,
                playSound: false
            )
            return
        }

        var turns = await MeetingRecordingTranscriber.transcribe(
            stereoURL: recordingURL,
            model: transcriptionConfiguration.model,
            requestContext: transcriptionConfiguration.requestContext,
            serviceRegistry: serviceRegistry,
            existingDiarizer: diarizer,
            existingMicDiarizer: micDiarizer
        )
        for index in turns.indices {
            turns[index].text = WordReplacementService.shared.applyReplacements(to: turns[index].text, using: modelContext)
        }

        let duration = await AudioFileMetadata.duration(for: recordingURL)
        let hasSpeech = turns.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if !hasSpeech {
            guard duration > Self.minimumMeaningfulMeetingDurationSeconds else {
                try? FileManager.default.removeItem(at: recordingURL)
                return
            }
        }

        let library = SpeakerLibraryStore.shared
        let transcription = Transcription(
            text: hasSpeech ? "" : String(localized: "(no speech detected)"),
            duration: duration,
            audioFileURL: recordingURL.absoluteString,
            transcriptionModelName: transcriptionConfiguration.model.displayName,
            transcriptionStatus: .completed,
            isMeetingRecording: true
        )
        transcription.timestamp = startedAt
        // Reuse the session's own meeting id (not the fresh one `Transcription.init` generates) -
        // see `toggleMeetingCapture`'s `sessionMeetingID` doc comment.
        transcription.id = meetingID

        if hasSpeech {
            let channels = (try? MeetingRecordingWriter.readChannels(from: recordingURL)) ?? (mic: [], system: [])
            turns = await MeetingSpeakerIdentifier.assignSpeakers(
                to: turns, systemChannel: channels.system, micChannel: channels.mic,
                meetingID: meetingID, library: library,
                sessionIDBySlot: sessionIDBySlot, micSessionIDBySlot: micSessionIDBySlot)
            transcription.meetingTurns = turns
            transcription.text = MeetingSpeakerTranscriptRenderer.render(turns) { library.name(for: $0) }
        }

        modelContext.insert(transcription)
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        } catch {
            logger.error("❌ Failed to save meeting recording transcription: \(error, privacy: .public)")
        }
    }
}
