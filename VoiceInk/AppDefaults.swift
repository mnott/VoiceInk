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

    /// The color (and opacity) applied to a pinned iTerm2 session's background, as an 8-digit
    /// "RRGGBBAA" hex string (an optional leading "#" is accepted when reading it back, and a
    /// 6-digit "RRGGBB" string - fully opaque - still parses too, for values stored before
    /// opacity existed as a setting - see `PinnedDestinationManager.itermColor(fromHexString:)`).
    /// Stored as plain 8-bit-per-channel hex rather than iTerm2's native 16-bit components because
    /// that is what a SwiftUI `ColorPicker` naturally round-trips through; `PinnedDestinationManager`
    /// upscales each RGB channel by 257 (0...255 -> 0...65535) when talking to iTerm2, and blends
    /// the alpha channel against the pane's original background rather than sending it to iTerm2
    /// at all (iTerm2's background color has no alpha channel - see the OPACITY discussion above
    /// `PinnedDestinationManager.markITermSessionPinned`). Registered with a default below so
    /// anyone who never opens this setting keeps seeing the original built-in green, fully opaque.
    static let pinnedITermTintColorHex = "PinnedITermTintColorHex"

    /// Whether Meeting Capture delivers a chunk on its own at a natural pause instead of only on
    /// the Send Meeting Chunk shortcut - see `VoiceInkEngine+Meeting`'s auto-send trigger. Off by
    /// default: silently auto-pasting into whatever is focused (or pinned) is not something to
    /// start doing without an explicit opt-in.
    static let sendMeetingChunksAutomatically = "SendMeetingChunksAutomatically"

    /// Whether Meeting Capture uses Nemotron 3 diarization (see `MeetingDiarizer`) to split the
    /// system-audio "Others" turns into individually labelled "Speaker N" turns. On by default:
    /// unlike auto-send, this changes no delivered content or destination, only a label - it only
    /// ever takes effect once the model is explicitly downloaded from the AI Models page (see
    /// `MeetingDiarizationModelManager`), so there is no silent download or behavior change for
    /// anyone who hasn't opted into that. Off falls back to the single generic "Others" label.
    static let identifyRemoteSpeakers = "MeetingCaptureIdentifyRemoteSpeakers"
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
            // Derived from the same constant `markITermSessionPinned` falls back to when this
            // key is missing or unparseable, so both paths agree on "untouched" behavior.
            PinnedDestinationSettingsKeys.pinnedITermTintColorHex: PinnedDestinationManager.hexString(
                fromITermColor: PinnedDestinationManager.defaultPinnedBackgroundColor),
            PinnedDestinationSettingsKeys.identifyRemoteSpeakers: true,

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
