import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum PinnedDestinationSettingsKeys {
    /// Whether a pinned iTerm2 session gets its badge variable marked while pinned - see
    /// `PinnedDestinationManager`'s "iTerm2 session marking" section for the full mechanism.
    /// Defaults to off (see `AppDefaults.registerDefaults` below): this writes to the user's
    /// terminal session via AppleScript, and even though it is invisible unless their iTerm2
    /// profile's Badge Text already references it, an app should not start touching terminal
    /// session state the user never asked for without an explicit opt-in.
    static let markPinnedITermSessionWithBadge = "MarkPinnedITermSessionWithBadge"
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            "hasCompletedOnboardingV2": false,
            "hasPreparedOnboardingV2": false,
            "enableAnnouncements": true,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "AutoEnterAfterTranscription": false,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,

            // Pinned Destination
            PinnedDestinationSettingsKeys.markPinnedITermSessionWithBadge: false,

            // UI & Behavior
            "IsMenuBarOnly": false,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Shortcuts
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            "EnhancementTimeoutSeconds": 7,
            "EnhancementRetryOnTimeout": true,

            // Model
            "PrewarmModelOnWake": true,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
