import AppKit
import SwiftUI

/// Settings for the pinned-destination feature, split into two sections so each
/// reads as what it actually does: the toggle hotkey, and - separately - the list
/// of per-app delivery options VoiceInk applies after delivering dictated text to a
/// pinned destination. The two were previously one section and users mistook the
/// app list for a way to pick the pin target itself, when pinning is always done
/// live via the hotkey; this list only ever controls how delivery behaves per app.
struct PinnedDestinationSettingsSection: View {
    @ObservedObject private var rulesManager = PinnedDestinationEnterRulesManager.shared
    @State private var selectedBundleIdentifier: String = ""
    @AppStorage(PinnedDestinationSettingsKeys.highlightPinnedITermSession)
    private var highlightPinnedITermSession = false
    @AppStorage(PinnedDestinationSettingsKeys.pinnedITermTintColorHex)
    private var pinnedITermTintColorHex = PinnedDestinationManager.hexString(
        fromITermColor: PinnedDestinationManager.defaultPinnedBackgroundColor)
    @AppStorage(PinnedDestinationSettingsKeys.sendMeetingChunksAutomatically)
    private var sendMeetingChunksAutomatically = false
    @AppStorage(PinnedDestinationSettingsKeys.identifyRemoteSpeakers)
    private var identifyRemoteSpeakers = true

    @State private var meetingShortcutBindingCounts: [ShortcutAction: Int] = [
        .meetingCapture: ShortcutStore.shortcuts(for: .meetingCapture).count,
        .meetingChunk: ShortcutStore.shortcuts(for: .meetingChunk).count,
    ]
    @State private var pendingMeetingShortcutSlots: [ShortcutAction: Int] = [:]

    /// Reads/writes the tint color AND opacity preference through SwiftUI's `Color`, going via
    /// `NSColor`'s sRGB representation rather than any other color space - `ColorPicker`'s
    /// underlying `Color` is not guaranteed to already be sRGB, and writing un-converted
    /// components into the "RRGGBBAA" hex string would silently store the wrong color. Opacity
    /// round-trips as `Color`'s own alpha/opacity channel - it is NOT applied to what gets sent
    /// to iTerm2 here; that blending happens in `PinnedDestinationManager.markITermSessionPinned`
    /// against the pane's actual original background, which this view has no access to (see the
    /// OPACITY discussion there for why). The getter falls back to the built-in default, fully
    /// opaque, on a malformed/missing stored hex, mirroring
    /// `PinnedDestinationManager.pinnedTintColor()`'s own fallback so the swatch shown here never
    /// disagrees with what actually gets applied.
    private var pinnedITermTintColor: Binding<Color> {
        Binding(
            get: {
                let tint =
                    PinnedDestinationManager.itermColor(fromHexString: pinnedITermTintColorHex)
                    ?? PinnedDestinationManager.ITermTintColor(
                        color: PinnedDestinationManager.defaultPinnedBackgroundColor, alpha: 1.0)
                return Color(
                    red: Double(tint.color.red) / 65535,
                    green: Double(tint.color.green) / 65535,
                    blue: Double(tint.color.blue) / 65535,
                    opacity: tint.alpha
                )
            },
            set: { newColor in
                guard let sRGB = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                pinnedITermTintColorHex = String(
                    format: "%02X%02X%02X%02X",
                    Int((sRGB.redComponent * 255).rounded()),
                    Int((sRGB.greenComponent * 255).rounded()),
                    Int((sRGB.blueComponent * 255).rounded()),
                    Int((sRGB.alphaComponent * 255).rounded())
                )
            }
        )
    }

    private var addableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { app in !rulesManager.rules.contains { $0.bundleIdentifier == app.bundleIdentifier } }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Group {
            Section {
                LabeledContent("Toggle Pinned Destination") {
                    ShortcutRecorder(action: .pinDestination) {}
                        .controlSize(.small)
                }

                Toggle("Tint Pinned iTerm2 Session", isOn: $highlightPinnedITermSession)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(
                        "Give the pinned pane a colored background while it is pinned, so you can spot it among many panes. The original color is restored when the pin ends."
                    )

                // Hidden rather than merely disabled while the toggle is off: a visible-but-inert
                // picker would suggest it has some effect on its own, when the toggle above is
                // what actually turns tinting on or off.
                if highlightPinnedITermSession {
                    ColorPicker("Tint Color", selection: pinnedITermTintColor, supportsOpacity: true)
                        .controlSize(.small)
                        .help(
                            "The background color applied to the pinned iTerm2 session while it is pinned. The opacity slider controls how strongly it blends over the pane's existing background, not how see-through the window becomes."
                        )
                }
            } header: {
                Text("Pinned Destination")
            } footer: {
                Text(
                    "Focus something you can type into, then use this shortcut to pin it. Dictation is then delivered there without switching focus, until you toggle the pin off. When the destination is an iTerm2 session, tinting it (above) can help you spot which pane is pinned when several are open - pick the tint color and its opacity with the color well, and the original background color is captured first and put back automatically when the pin changes or clears. Opacity blends the tint over that original background rather than making the pane see-through, so a lower value gives a subtler wash of color instead of a transparent window."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                ForEach(rulesManager.rules) { rule in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 8) {
                                Toggle(
                                    "Enter Insert Mode First",
                                    isOn: Binding(
                                        get: { rule.sendInsertPrefix },
                                        set: {
                                            rulesManager.setRule(
                                                bundleIdentifier: rule.bundleIdentifier,
                                                appName: rule.appName,
                                                appendReturn: rule.appendReturn,
                                                sendInsertPrefix: $0,
                                                appendSpace: rule.appendSpace
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(
                                    "Switch this app into typing mode before sending dictated text, so it is entered as text instead of being interpreted as commands. Safe either way - if it was already in typing mode, nothing is left behind."
                                )

                                Toggle(
                                    "Submit With Return",
                                    isOn: Binding(
                                        get: { rule.appendReturn },
                                        set: {
                                            rulesManager.setRule(
                                                bundleIdentifier: rule.bundleIdentifier,
                                                appName: rule.appName,
                                                appendReturn: $0,
                                                sendInsertPrefix: rule.sendInsertPrefix,
                                                appendSpace: rule.appendSpace
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("Press Return after delivering dictated text to this app, to submit it automatically")

                                Toggle(
                                    "Append Space",
                                    isOn: Binding(
                                        // Shows what will actually happen, not what is stored: with
                                        // Submit With Return on, no space is appended, so a switch
                                        // left visibly on would contradict the behaviour beside it.
                                        // The stored preference is untouched and reappears as soon
                                        // as submission is turned back off.
                                        get: { !rule.appendReturn && rule.appendSpace },
                                        set: {
                                            rulesManager.setRule(
                                                bundleIdentifier: rule.bundleIdentifier,
                                                appName: rule.appName,
                                                appendReturn: rule.appendReturn,
                                                sendInsertPrefix: rule.sendInsertPrefix,
                                                appendSpace: $0
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(rule.appendReturn)
                                .help(
                                    "Add a space after the dictated text so you can keep dictating the next sentence without typing one yourself. Not used when Submit With Return is on."
                                )

                                Button {
                                    rulesManager.removeRule(bundleIdentifier: rule.bundleIdentifier)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop controlling delivery behavior for this app")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(rule.appName.isEmpty ? rule.bundleIdentifier : rule.appName)
                            // Every app starts out at the same built-in defaults (just
                            // insert, no insert-mode switch, no submission) when added to
                            // this list - there is no more per-app default to diverge from
                            // - so this only tells the user whether either option has been
                            // turned on for this row.
                            Text(isCustomizedAwayFromDefaults(rule) ? "Custom" : "Default")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                LabeledContent("Add App") {
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedBundleIdentifier) {
                            Text("Choose a running app…").tag("")
                            ForEach(addableApps, id: \.bundleIdentifier) { app in
                                Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                                    .tag(app.bundleIdentifier ?? "")
                            }
                        }
                        .labelsHidden()
                        .disabled(addableApps.isEmpty)

                        Button("Add") {
                            addSelectedApp()
                        }
                        .disabled(selectedBundleIdentifier.isEmpty)
                    }
                }
                .help("Add a running app to this list to control its delivery options")
            } header: {
                Text("Delivery Options")
            } footer: {
                Text(
                    "Add an app here to control how dictated text is delivered to it: switch it into typing mode first, submit with Return afterward, and whether to leave a trailing space so you can keep dictating. A space is added by default when the text is not submitted. Whether the first two work depends on the app, so neither is guaranteed for every one."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                meetingShortcutRow(action: .meetingCapture, title: "Toggle Meeting Capture")
                meetingShortcutRow(action: .meetingChunk, title: "Send Meeting Chunk")

                Toggle("Send Chunks Automatically", isOn: $sendMeetingChunksAutomatically)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(
                        "While Meeting Capture is running, automatically send a chunk at a natural pause instead of waiting for the Send Meeting Chunk shortcut. The shortcut keeps working and resets the timing."
                    )

                Toggle("Identify Remote Speakers", isOn: $identifyRemoteSpeakers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(
                        "Label each remote participant separately (\"Speaker 1\", \"Speaker 2\", ...) instead of one shared \"Others\" label, once the Nemotron 3 Diarization model is downloaded from the AI Models page. Uses extra CPU/Neural Engine time while a meeting is running."
                    )
            } header: {
                Text("Meeting Capture")
            } footer: {
                Text(
                    "Records the microphone and everything your Mac plays - the other participants in a Teams/Zoom call, for example - without muting or pausing the call. Each press of Send Meeting Chunk transcribes the audio captured since the last press and delivers it to the pinned destination (or the cursor) while recording keeps running. macOS asks once for System Audio Recording permission the first time you use this. Echo cancellation removes what the speakers played back out of the microphone recording, so the other participants are not captured twice even without headphones. Either action can have more than one shortcut - useful for pairing a keyboard combo with a mouse button combo. Download the Nemotron 3 Diarization model on the AI Models page to identify remote speakers individually instead of one shared \"Others\" label."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
                guard let action = notification.object as? ShortcutAction,
                    action == .meetingCapture || action == .meetingChunk
                else {
                    return
                }
                refreshMeetingShortcutBindingCount(for: action)
            }
        }
    }

    private func meetingShortcutRow(action: ShortcutAction, title: LocalizedStringKey) -> some View {
        let boundCount = meetingShortcutBindingCounts[action, default: 0]
        let rowCount = max(1, boundCount + pendingMeetingShortcutSlots[action, default: 0])

        func collapsePendingSlot(forIndex index: Int) {
            guard index >= boundCount else { return }
            pendingMeetingShortcutSlots[action, default: 0] =
                max(0, pendingMeetingShortcutSlots[action, default: 0] - 1)
        }

        return LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: action,
                            index: index,
                            onCancel: {
                                collapsePendingSlot(forIndex: index)
                            }
                        ) {
                            refreshMeetingShortcutBindingCount(for: action)
                            collapsePendingSlot(forIndex: index)
                        }
                        .controlSize(.small)

                        Button {
                            if index < boundCount {
                                ShortcutStore.removeShortcut(at: index, for: action)
                                refreshMeetingShortcutBindingCount(for: action)
                            } else {
                                collapsePendingSlot(forIndex: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this shortcut")
                    }
                }

                Button("Add Shortcut") {
                    pendingMeetingShortcutSlots[action, default: 0] += 1
                }
                .controlSize(.small)
            }
        }
    }

    private func refreshMeetingShortcutBindingCount(for action: ShortcutAction) {
        meetingShortcutBindingCounts[action] = ShortcutStore.shortcuts(for: action).count
    }

    private func isCustomizedAwayFromDefaults(_ rule: PinnedDestinationEnterRule) -> Bool {
        rule.appendReturn != PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: rule.bundleIdentifier)
            || rule.sendInsertPrefix
                != PinnedDestinationEnterRuleStore.defaultSendInsertPrefix(forBundleIdentifier: rule.bundleIdentifier)
            || rule.appendSpace
                != PinnedDestinationEnterRuleStore.defaultAppendSpace(forBundleIdentifier: rule.bundleIdentifier)
    }

    private func addSelectedApp() {
        guard
            let app = addableApps.first(where: { $0.bundleIdentifier == selectedBundleIdentifier }),
            let bundleIdentifier = app.bundleIdentifier
        else {
            return
        }

        rulesManager.setRule(
            bundleIdentifier: bundleIdentifier,
            appName: app.localizedName ?? bundleIdentifier,
            appendReturn: PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: bundleIdentifier),
            sendInsertPrefix: PinnedDestinationEnterRuleStore.defaultSendInsertPrefix(
                forBundleIdentifier: bundleIdentifier),
            appendSpace: PinnedDestinationEnterRuleStore.defaultAppendSpace(forBundleIdentifier: bundleIdentifier)
        )
        selectedBundleIdentifier = ""
    }
}
