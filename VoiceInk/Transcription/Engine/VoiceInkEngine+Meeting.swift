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

    func toggleMeetingCapture() {
        if isMeetingCaptureActive {
            let capture = meetingCapture
            isMeetingCaptureActive = false
            meetingCapture = nil

            if let capture {
                let cut = capture.cut(forceFullRelease: true)
                deliverMeetingChunk(
                    cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: false,
                    isAutomatic: false)
            }
            let sessionRecordingURL = capture?.recordingURL
            capture?.stop()

            if let sessionRecordingURL {
                enqueueMeetingRecordingTranscription(recordingURL: sessionRecordingURL)
            }

            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture stopped"),
                type: .info
            )
        } else {
            let recordingURL = recordingsDirectory.appendingPathComponent("meeting-\(UUID().uuidString).wav")
            let capture = MeetingAudioCapture(recordingURL: recordingURL)
            capture.onAutoSendTrigger = { [weak self] in
                Task { @MainActor in
                    self?.sendMeetingChunkAutomatically()
                }
            }
            capture.start()
            // A dictation already in flight when a meeting capture starts mid-recording must
            // still be excluded - `recordingState`'s `didSet` only fires on later transitions.
            capture.isDictationActive = Self.isDictationRecordingState(recordingState)
            meetingCapture = capture
            isMeetingCaptureActive = true

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
        }
    }

    /// Manual (hotkey) chunk send. Delays the cut (see `MeetingAudioCapture.cutForManualSend`) and
    /// forces full release, so the last word spoken right up to the key press - whose VAD region
    /// may not have closed yet - is never deferred to a later chunk the way an automatic cut's
    /// open-utterance check would defer it.
    func sendMeetingChunk() async {
        guard isMeetingCaptureActive, let capture = meetingCapture else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture is not running"),
                type: .info
            )
            return
        }
        let cut = await capture.cutForManualSend()
        deliverMeetingChunk(
            cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: true,
            isAutomatic: false)
    }

    /// Called from `MeetingAudioCapture.onAutoSendTrigger` (see `MeetingAutoSendPolicy`) once a
    /// natural turn boundary is found. Goes through exactly the same delivery path as the manual
    /// hotkey - same labels, same pinned delivery, silent, no History record - just without the
    /// "nothing to send" notification a user press would show, and without forcing full release
    /// (an open utterance is deferred to the next chunk, same as any other automatic cut).
    func sendMeetingChunkAutomatically() {
        guard isMeetingCaptureActive, let capture = meetingCapture else { return }
        let cut = capture.cut()
        deliverMeetingChunk(
            cut: cut, isCapturingSystemAudio: capture.isCapturingSystemAudio, notifyWhenEmpty: false,
            isAutomatic: true)
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

        // Mic-only sessions have no second channel to order turns against, so they keep the
        // plain, unlabeled whole-track transcription they always had.
        let combinedText: String
        if isCapturingSystemAudio {
            let result = await MeetingTurnTranscriber.transcribe(
                mic: cut.mic, system: cut.system,
                model: transcriptionConfiguration.model, requestContext: transcriptionConfiguration.requestContext,
                serviceRegistry: serviceRegistry,
                micNoiseFloor: cut.micNoiseFloor, systemNoiseFloor: cut.systemNoiseFloor)
            combinedText = MeetingTurnTranscriptRenderer.render(result.turns)
        } else {
            let micText = await transcribedText(for: cut.mic, transcriptionConfiguration: transcriptionConfiguration)
            combinedText = MeetingTranscriptCombiner.combine(micText: micText, systemText: "", isCapturingSystemAudio: false)
        }

        // `meetingChunkDeliveryCoordinator.submit` discards `audioURL` itself (via `discard`) when
        // `combinedText` is empty - see its doc comment - so the two silent/failed tracks case
        // (previously delivered as an empty `pretranscribedText`, a no-op) is handled there.
        meetingChunkDeliveryCoordinator.submit(
            text: combinedText,
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

    private func enqueueMeetingRecordingTranscription(recordingURL: URL) {
        let previousTask = meetingChunkTask
        meetingChunkTask = Task { [weak self] in
            await previousTask?.value
            await self?.transcribeAndSaveMeetingRecording(recordingURL: recordingURL)
        }
    }

    private func transcribeAndSaveMeetingRecording(recordingURL: URL) async {
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

        var text = await MeetingRecordingTranscriber.transcribe(
            stereoURL: recordingURL,
            model: transcriptionConfiguration.model,
            requestContext: transcriptionConfiguration.requestContext,
            serviceRegistry: serviceRegistry
        )
        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)

        let duration = await AudioFileMetadata.duration(for: recordingURL)

        if text.isEmpty {
            guard duration > Self.minimumMeaningfulMeetingDurationSeconds else {
                try? FileManager.default.removeItem(at: recordingURL)
                return
            }
            text = String(localized: "(no speech detected)")
        }

        let transcription = Transcription(
            text: text,
            duration: duration,
            audioFileURL: recordingURL.absoluteString,
            transcriptionModelName: transcriptionConfiguration.model.displayName,
            transcriptionStatus: .completed,
            isMeetingRecording: true
        )
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
