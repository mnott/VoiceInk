import LaunchAtLogin
import OSLog
import SwiftUI

struct MenuBarView: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MenuBarWindowFlow")

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var pinnedDestinationManager = PinnedDestinationManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @AppStorage(PinnedDestinationSettingsKeys.diarizeMicInPerson) private var diarizeMicInPerson = false
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    // ShortcutStore is not observable; bump this so recorded hotkeys in the Meeting
    // submenu refresh when a binding changes (same pattern as the Settings rows).
    @State private var shortcutBindingsRevision = 0

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            shortcutBindingsRevision += 1
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                showMainWindow(reason: "Complete Onboarding")
            }

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button("Toggle Recorder") {
                recorderUIManager.handleToggleRecorderPanelNotification()
            }

            if let pinned = pinnedDestinationManager.pinned {
                Divider()

                // `displayLabel`, not `appName`: with several iTerm2 panes open, the app
                // name alone can't tell the user which one is pinned.
                Text(String(format: String(localized: "Pinned: %@"), pinned.displayLabel))
                    .foregroundColor(.secondary)

                Button("Unpin") {
                    pinnedDestinationManager.unpin(notify: true)
                }
            }

            if engine.isMeetingCaptureActive, !engine.currentMeetingSpeakerLabel.isEmpty {
                Divider()

                Text(String(format: String(localized: "Speaking: %@"), engine.currentMeetingSpeakerLabel))
                    .foregroundColor(.secondary)
            }

            Divider()

            meetingMenu

            Divider()

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Button {
                        modeManager.setActiveConfiguration(config)
                    } label: {
                        let isActive = modeManager.currentEffectiveConfiguration?.id == config.id
                        Text(isActive ? "\(config.name)  ✓" : config.name)
                    }
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    showMainWindowAndNavigate(to: "Modes", reason: "Manage Modes")
                }

                Button("Manage Models") {
                    showMainWindowAndNavigate(to: "AI Models", reason: "Manage Models")
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(.system(size: 11, weight: .medium))
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Menu {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                    } label: {
                        let isActive = audioDeviceManager.getCurrentDevice() == device.id
                        Text(isActive ? "\(device.name)  ✓" : device.name)
                    }
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("History") {
                menuBarManager.openHistoryWindow()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                let shouldShowMainWindow = menuBarManager.isMenuBarOnly
                menuBarManager.toggleMenuBarOnly()

                if shouldShowMainWindow {
                    showMainWindow(reason: "Show Dock Icon")
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }

            Divider()

            Button("Settings") {
                showMainWindowAndNavigate(to: "Settings", reason: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // Always visible: doubles as a hotkey reference even while capture is off.
    private var meetingMenu: some View {
        Menu {
            Button {
                Task { await engine.toggleMeetingCapture() }
            } label: {
                Text(
                    "Meeting Capture"
                        + (engine.isMeetingCaptureActive ? " (Active)" : "")
                        + meetingHotkeyHint(for: .meetingCapture)
                )
            }

            Button {
                Task { await engine.sendMeetingChunk() }
            } label: {
                Text("Send Meeting Chunk" + meetingHotkeyHint(for: .meetingChunk))
            }
            .disabled(!engine.isMeetingCaptureActive)

            Button {
                engine.calibrateMeetingSilence()
            } label: {
                Text("Calibrate Silence" + meetingHotkeyHint(for: .calibrateMeetingSilence))
            }
            .disabled(!engine.isMeetingCaptureActive)

            Button {
                NameSpeakerManager.shared.toggle(engine: engine)
            } label: {
                Text("Name Speaker" + meetingHotkeyHint(for: .nameSpeaker))
            }
            .disabled(!engine.isMeetingCaptureActive)

            Divider()

            // Hybrid capture: with this on, an in-person meeting's room speakers are diarized on
            // the mic channel while remote participants keep being diarized on the system channel
            // (see `MeetingCaptureModeDetector`). Decided once at capture start - hence locked
            // while a session is running.
            Toggle("Diarize Microphone (Room Speakers)", isOn: $diarizeMicInPerson)
                .disabled(engine.isMeetingCaptureActive)
            if engine.isMeetingCaptureActive {
                Text("Applies to the next meeting")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } label: {
            HStack {
                Image(systemName: "record.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Meeting")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
            }
        }
    }

    /// Recorded global hotkeys for an action, right-aligned by space padding (a plain
    /// HStack label collapses inside a Menu). Empty when the action is unbound.
    private func meetingHotkeyHint(for action: ShortcutAction) -> String {
        _ = shortcutBindingsRevision

        let shortcuts = ShortcutStore.shortcuts(for: action)
        guard !shortcuts.isEmpty else { return "" }

        return "    " + shortcuts.map(\.displayString).joined(separator: ", ")
    }

    private func showMainWindow(reason: String) {
        let existingWindow = WindowManager.shared.currentMainWindow()
        logger.notice(
            "🧭 Menu bar requested main window. reason=\(reason, privacy: .public); menuBarOnly=\(self.menuBarManager.isMenuBarOnly, privacy: .public); hasExistingMainWindow=\((existingWindow != nil), privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
        )
        menuBarManager.activateForPresentedWindow(reason: reason)

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
            logger.notice(
                "🧭 Menu bar requested SwiftUI to create/open main window. reason=\(reason, privacy: .public); path=createViaOpenWindow"
            )
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
            logger.notice(
                "🧭 Menu bar requested SwiftUI to open existing main window and asked WindowManager to present it. reason=\(reason, privacy: .public); path=existingWindow"
            )
        }
    }

    private func showMainWindowAndNavigate(to destination: String, reason: String) {
        logger.notice(
            "🧭 Menu bar navigation requested. reason=\(reason, privacy: .public); destination=\(destination, privacy: .public); selectedBefore=\(self.mainWindowNavigation.selectedView.rawValue, privacy: .public)"
        )
        mainWindowNavigation.navigate(to: destination)
        logger.notice(
            "🧭 Menu bar navigation state updated. reason=\(reason, privacy: .public); destination=\(destination, privacy: .public); selectedAfter=\(self.mainWindowNavigation.selectedView.rawValue, privacy: .public)"
        )
        showMainWindow(reason: reason)
    }
}
