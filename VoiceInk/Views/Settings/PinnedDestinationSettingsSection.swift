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
    @AppStorage(PinnedDestinationSettingsKeys.markPinnedITermSessionWithBadge)
    private var markPinnedITermSessionWithBadge = false

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

                Toggle("Mark Pinned iTerm2 Session With a Badge", isOn: $markPinnedITermSessionWithBadge)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(
                        "Requires the iTerm2 profile's Badge Text (Settings > Profiles > General > Badge) to include \\(user.voiceink_pinned) - VoiceInk can only set that variable's value, not the badge itself"
                    )
            } header: {
                Text("Pinned Destination")
            } footer: {
                Text(
                    "Focus something you can type into, then use this shortcut to pin it. Dictation is then delivered there without switching focus, until you toggle the pin off. When the destination is an iTerm2 session, marking it with a badge (above) can help you spot which pane is pinned when several are open - it is reverted automatically when the pin changes or clears, and only appears if your iTerm2 profile's badge is configured to show it."
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
                                                sendInsertPrefix: $0
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(
                                    "Switch this app into typing mode before sending dictated text, so it is entered as text instead of being interpreted as commands"
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
                                                sendInsertPrefix: rule.sendInsertPrefix
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("Press Return after delivering dictated text to this app, to submit it automatically")

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
                    "By default, VoiceInk only inserts the dictated text. Add an app here to also switch it into typing mode first, submit with Return afterward, or both. Whether either works depends on the app, so neither is guaranteed for every one."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private func isCustomizedAwayFromDefaults(_ rule: PinnedDestinationEnterRule) -> Bool {
        rule.appendReturn != PinnedDestinationEnterRuleStore.defaultAppendReturn(forBundleIdentifier: rule.bundleIdentifier)
            || rule.sendInsertPrefix
                != PinnedDestinationEnterRuleStore.defaultSendInsertPrefix(forBundleIdentifier: rule.bundleIdentifier)
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
                forBundleIdentifier: bundleIdentifier)
        )
        selectedBundleIdentifier = ""
    }
}
