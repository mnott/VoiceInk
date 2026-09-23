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

            deliverMeetingChunk(from: capture, notifyWhenEmpty: false, forceFullRelease: true)
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

    func sendMeetingChunk() {
        guard isMeetingCaptureActive else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting capture is not running"),
                type: .info
            )
            return
        }
        deliverMeetingChunk(from: meetingCapture, notifyWhenEmpty: true)
    }

    /// Called from `MeetingAudioCapture.onAutoSendTrigger` (see `MeetingAutoSendPolicy`) once a
    /// natural turn boundary is found. Goes through exactly the same delivery path as the manual
    /// hotkey - same labels, same pinned delivery, silent, no History record - just without the
    /// "nothing to send" notification a user press would show.
    func sendMeetingChunkAutomatically() {
        guard isMeetingCaptureActive else { return }
        deliverMeetingChunk(from: meetingCapture, notifyWhenEmpty: false)
    }

    // MARK: - Per-chunk delivery (paste-only, never saved to History)

    private func deliverMeetingChunk(
        from capture: MeetingAudioCapture?, notifyWhenEmpty: Bool, forceFullRelease: Bool = false
    ) {
        guard let capture else { return }
        let cut = capture.cut(forceFullRelease: forceFullRelease)
        let isCapturingSystemAudio = capture.isCapturingSystemAudio

        // Manual (`sendMeetingChunk`) always notifies when empty; the automatic trigger and the
        // stop-time forced flush never do - this is the same distinction those two call sites use,
        // read back out here instead of adding a separate parameter just for the log line.
        let isAutomatic = !notifyWhenEmpty && !forceFullRelease
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

        // Chained after the previous chunk's task so deliveries stay in order and the local
        // Whisper model, which is not safe to run concurrently, only ever transcribes one
        // meeting chunk (or the final meeting recording) at a time.
        let previousTask = meetingChunkTask
        meetingChunkTask = Task { [weak self] in
            await previousTask?.value
            await self?.transcribeAndDeliverMeetingChunk(cut: cut, isCapturingSystemAudio: isCapturingSystemAudio)
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

    private func transcribeAndDeliverMeetingChunk(
        cut: MeetingAudioCapture.MeetingCut, isCapturingSystemAudio: Bool
    ) async {
        // Scratch file only: a chunk is paste-only and never becomes a History record, so its
        // audio has no reason to live in the (permanent) recordings directory - it is deleted
        // once transcription is done with it.
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

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
            let turns = await MeetingTurnTranscriber.transcribe(
                mic: cut.mic, system: cut.system,
                model: transcriptionConfiguration.model, requestContext: transcriptionConfiguration.requestContext,
                serviceRegistry: serviceRegistry,
                micNoiseFloor: cut.micNoiseFloor, systemNoiseFloor: cut.systemNoiseFloor)
            combinedText = MeetingTurnTranscriptRenderer.render(turns)
        } else {
            let micText = await transcribedText(for: cut.mic, transcriptionConfiguration: transcriptionConfiguration)
            combinedText = MeetingTranscriptCombiner.combine(micText: micText, systemText: "", isCapturingSystemAudio: false)
        }

        // Transient: never inserted into modelContext, never saved, never posted as a History
        // event - only `pipeline.run`'s filter/format/word-replacement/enhancement/delivery runs
        // on it. See `TranscriptionPipeline.run`'s `saveToHistory` doc comment.
        let transcription = makeRecordingTranscription(
            for: audioURL,
            text: "",
            duration: 0,
            transcriptionStatus: .pending
        )

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: nil,
            pretranscribedText: combinedText,
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
