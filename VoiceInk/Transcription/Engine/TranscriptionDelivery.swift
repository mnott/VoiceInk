import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if PinnedDestinationManager.shared.pinned != nil {
            await deliverToPinnedDestination(request, actions: actions)
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, output: request.output, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    /// Routes delivery to the pinned destination instead of `CursorPaster`, which
    /// pastes into whatever is frontmost - the opposite of what a pin is for, since
    /// the pin exists precisely so the user can look elsewhere while dictating.
    private func deliverToPinnedDestination(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let textToDeliver = deliverableText(from: text)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        await PinnedDestinationManager.shared.deliver(text: textToDeliver)
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        // A custom command delivers text just like a paste does, so it has to honor
        // auto-send the same way. Without this the global "Auto Enter after
        // transcription" preference silently applies to paste output ONLY, and any mode
        // routing through a command can never submit - the text lands and simply sits
        // there. The command's own delivery mechanism is irrelevant here: whatever it
        // did, the cursor ends up in the app the user is looking at, which is exactly
        // where the paste path posts its key too.
        let autoSendKey = Self.resolvedAutoSendKey(for: item.output)

        Task {
            let delivered = await runCustomCommand(command: command, commandText: commandText)
            // Never submit after a failed command: the text never arrived, so a Return
            // would fire into whatever the user has focused with nothing in front of it.
            guard delivered, autoSendKey.isEnabled else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.autoSendDelaySeconds * 1_000_000_000))
            CursorPaster.performAutoSend(autoSendKey)
        }
    }

    /// The auto-send key to use after text has been delivered: the mode's own choice
    /// wins, and the app-wide "Auto Enter after transcription" preference is the
    /// fallback when the mode leaves it at none.
    private static func resolvedAutoSendKey(for output: OutputRuntimeConfiguration) -> AutoSendKey {
        if output.autoSendKey != .none { return output.autoSendKey }
        return UserDefaults.standard.bool(forKey: "AutoEnterAfterTranscription") ? .enter : .none
    }

    /// Gap between text landing and the submit key. Long enough for terminal emulators,
    /// which needed more than the original 100ms.
    private static let autoSendDelaySeconds: Double = 0.5

    @discardableResult
    private func runCustomCommand(command: String, commandText: String) async -> Bool {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
            return true
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
            return false
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, output: OutputRuntimeConfiguration, actions: Actions) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)

        var autoSendKey: AutoSendKey = output.outputMode == .paste ? output.autoSendKey : .none
        // Global fallback: send Return unless the active mode already picked a key.
        if autoSendKey == .none, output.outputMode == .paste,
            UserDefaults.standard.bool(forKey: "AutoEnterAfterTranscription")
        {
            autoSendKey = .enter
        }
        Task { @MainActor in
            _ = await pasteTask.value

            if autoSendKey.isEnabled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                CursorPaster.performAutoSend(autoSendKey)
            }
        }
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel().usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
