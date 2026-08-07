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
    /// Whether a pinned iTerm2 session gets its background tinted while pinned - see
    /// `PinnedDestinationManager`'s "iTerm2 session marking" section for the full mechanism.
    /// Defaults to off (see `AppDefaults.registerDefaults` below): this changes the user's
    /// terminal color scheme for as long as the pin lasts, which an app should never start
    /// doing without an explicit opt-in.
    static let highlightPinnedITermSession = "HighlightPinnedITermSession"
}

enum AppDefaults {
    /// Key the pinned-session marker used before it tinted the background: it set an iTerm2
    /// badge variable instead, which only ever showed anything if the user had already wired
    /// that variable into their profile's Badge Text. Kept solely to carry a prior opt-in
    /// across - see `migratePinnedITermMarkerPreference`.
    private static let legacyPinnedITermBadgeKey = "MarkPinnedITermSessionWithBadge"

    /// Carries a user who had already opted into marking the pinned session over to the key
    /// that replaced it. Without this the toggle silently reverts to off on upgrade, and the
    /// feature reads as broken rather than as switched off - which is exactly how it was
    /// reported. Runs once: it only writes when the new key has no value of its own.
    private static func migratePinnedITermMarkerPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PinnedDestinationSettingsKeys.highlightPinnedITermSession) == nil,
            defaults.object(forKey: legacyPinnedITermBadgeKey) != nil
        else {
            return
        }

        defaults.set(
            defaults.bool(forKey: legacyPinnedITermBadgeKey),
            forKey: PinnedDestinationSettingsKeys.highlightPinnedITermSession
        )
        defaults.removeObject(forKey: legacyPinnedITermBadgeKey)
    }

    static func registerDefaults() {
        migratePinnedITermMarkerPreference()

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
            PinnedDestinationSettingsKeys.highlightPinnedITermSession: false,

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
