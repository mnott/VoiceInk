import Foundation
import os

/// Per-app delivery options for the pinned-destination feature, keyed by bundle
/// identifier: whether a Return key press should be appended after dictated text is
/// delivered, and whether an insert-mode prefix should be sent first.
struct PinnedDestinationEnterRule: Codable, Identifiable, Equatable {
    var bundleIdentifier: String
    var appName: String
    var appendReturn: Bool
    /// Sends the letter "i" before the transcript when delivering to an iTerm2 session,
    /// to switch a modal terminal UI (an interactive coding agent, for example) into
    /// insert/typing mode first - otherwise dictated text can be swallowed as commands
    /// instead of being entered as text. Defaults to false for every app: like
    /// `appendReturn`, there is no implicit per-app default, only what this list shows.
    var sendInsertPrefix: Bool
    /// Appends a single space after the dictated text when it is NOT being submitted. Dictating
    /// several sentences into the same field otherwise runs them together, leaving the user to
    /// type the separator by hand every time. Meaningless when `appendReturn` is on - the text
    /// is submitted rather than continued - so delivery ignores it in that case.
    var appendSpace: Bool

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        appName: String,
        appendReturn: Bool,
        sendInsertPrefix: Bool = false,
        appendSpace: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appendReturn = appendReturn
        self.sendInsertPrefix = sendInsertPrefix
        self.appendSpace = appendSpace
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, appName, appendReturn, sendInsertPrefix, appendSpace
    }

    // Custom decode so rules persisted before `sendInsertPrefix` existed still decode
    // cleanly: the synthesized Decodable would throw `keyNotFound` on the missing key
    // and `decode(_:)` below would silently drop the whole stored rule list. Encoding
    // stays synthesized - every stored property is Codable, so there is nothing custom
    // needed there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        appName = try container.decode(String.self, forKey: .appName)
        appendReturn = try container.decode(Bool.self, forKey: .appendReturn)
        sendInsertPrefix = try container.decodeIfPresent(Bool.self, forKey: .sendInsertPrefix) ?? false
        appendSpace = try container.decodeIfPresent(Bool.self, forKey: .appendSpace) ?? true
    }
}

/// Pure, side-effect-free logic for the enter-rule store: defaults, JSON persistence
/// shape, and rule lookup. Kept free of UserDefaults access in its lookup helpers so
/// it is trivially unit-testable.
enum PinnedDestinationEnterRuleStore {
    static let userDefaultsKey = "PinnedDestinationEnterRules"

    /// The built-in default when no explicit rule exists for a bundle id: insert the
    /// dictated text and do nothing else. There used to be a silent terminal-app
    /// special case here, but that meant an app's actual behavior could diverge from
    /// what the per-app list on screen showed - now that the list itself can express
    /// "submit for this app", the implicit default has no reason to differ per app.
    /// The list is the single source of truth for who gets Return.
    static func defaultAppendReturn(forBundleIdentifier _: String) -> Bool {
        false
    }

    /// Same reasoning as `defaultAppendReturn`: no implicit per-app default, only what
    /// the per-app list explicitly turns on.
    static func defaultSendInsertPrefix(forBundleIdentifier _: String) -> Bool {
        false
    }

    /// Unlike the other two, this defaults ON: continuing to dictate into the same field is the
    /// common case, and running two dictations together with no separator is never what the
    /// user meant. Turning it off is for fields where a trailing space is actively wrong.
    static func defaultAppendSpace(forBundleIdentifier _: String) -> Bool {
        true
    }

    /// Resolves the effective "append Return" behavior for a bundle id: an explicit
    /// rule wins, otherwise the built-in default for that bundle id applies.
    static func appendReturn(
        forBundleIdentifier bundleIdentifier: String,
        rules: [PinnedDestinationEnterRule]
    ) -> Bool {
        if let rule = rules.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return rule.appendReturn
        }
        return defaultAppendReturn(forBundleIdentifier: bundleIdentifier)
    }

    /// Resolves the effective "send insert-mode prefix" behavior for a bundle id,
    /// mirroring `appendReturn` above: an explicit rule wins, otherwise the unconditional
    /// default applies.
    static func sendInsertPrefix(
        forBundleIdentifier bundleIdentifier: String,
        rules: [PinnedDestinationEnterRule]
    ) -> Bool {
        if let rule = rules.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return rule.sendInsertPrefix
        }
        return defaultSendInsertPrefix(forBundleIdentifier: bundleIdentifier)
    }

    /// Resolves the effective "append a trailing space" behavior, mirroring the two above.
    static func appendSpace(
        forBundleIdentifier bundleIdentifier: String,
        rules: [PinnedDestinationEnterRule]
    ) -> Bool {
        if let rule = rules.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return rule.appendSpace
        }
        return defaultAppendSpace(forBundleIdentifier: bundleIdentifier)
    }

    /// The text to actually deliver: the transcript, plus a trailing space when one is wanted.
    /// A space is only ever added when the text is NOT being submitted - after a Return the
    /// field is gone, so a trailing space would either vanish or land at the start of whatever
    /// comes next. Kept pure and separate from delivery so both the AppleScript and the
    /// accessibility paths append identically rather than each re-deriving the rule.
    static func deliveredText(_ text: String, appendReturn: Bool, appendSpace: Bool) -> String {
        guard !appendReturn, appendSpace else { return text }
        return text + " "
    }

    static func decode(_ data: Data) -> [PinnedDestinationEnterRule] {
        (try? JSONDecoder().decode([PinnedDestinationEnterRule].self, from: data)) ?? []
    }

    static func encode(_ rules: [PinnedDestinationEnterRule]) -> Data? {
        try? JSONEncoder().encode(rules)
    }

    static func loadRules(from defaults: UserDefaults = .standard) -> [PinnedDestinationEnterRule] {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
        return decode(data)
    }

    static func saveRules(_ rules: [PinnedDestinationEnterRule], to defaults: UserDefaults = .standard) {
        guard let data = encode(rules) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }
}

/// UI-facing, published wrapper around `PinnedDestinationEnterRuleStore` for use from
/// SwiftUI settings and from the pinned-delivery path.
@MainActor
final class PinnedDestinationEnterRulesManager: ObservableObject {
    static let shared = PinnedDestinationEnterRulesManager()

    @Published private(set) var rules: [PinnedDestinationEnterRule]

    private init() {
        rules = PinnedDestinationEnterRuleStore.loadRules()
        // Diagnoses the "text arrived but Return did not" class of failure: if this
        // logs zero rules while the plist on disk clearly holds one, the store and the
        // app are not reading the same defaults, which no delivery-time log can show.
        Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PinnedDestinationEnterRules").notice(
            "Loaded \(self.rules.count, privacy: .public) enter rule(s): \(self.rules.map { "\($0.bundleIdentifier):\($0.appendReturn ? "return" : "insert")" }.joined(separator: ","), privacy: .public)"
        )
    }

    func appendReturn(forBundleIdentifier bundleIdentifier: String) -> Bool {
        PinnedDestinationEnterRuleStore.appendReturn(forBundleIdentifier: bundleIdentifier, rules: rules)
    }

    func sendInsertPrefix(forBundleIdentifier bundleIdentifier: String) -> Bool {
        PinnedDestinationEnterRuleStore.sendInsertPrefix(forBundleIdentifier: bundleIdentifier, rules: rules)
    }

    func appendSpace(forBundleIdentifier bundleIdentifier: String) -> Bool {
        PinnedDestinationEnterRuleStore.appendSpace(forBundleIdentifier: bundleIdentifier, rules: rules)
    }

    func setRule(
        bundleIdentifier: String,
        appName: String,
        appendReturn: Bool,
        sendInsertPrefix: Bool,
        appendSpace: Bool
    ) {
        if let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            rules[index].appendReturn = appendReturn
            rules[index].sendInsertPrefix = sendInsertPrefix
            rules[index].appendSpace = appendSpace
            rules[index].appName = appName
        } else {
            rules.append(
                PinnedDestinationEnterRule(
                    bundleIdentifier: bundleIdentifier,
                    appName: appName,
                    appendReturn: appendReturn,
                    sendInsertPrefix: sendInsertPrefix,
                    appendSpace: appendSpace
                ))
        }
        persist()
    }

    func removeRule(bundleIdentifier: String) {
        rules.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persist()
    }

    private func persist() {
        PinnedDestinationEnterRuleStore.saveRules(rules)
    }
}
