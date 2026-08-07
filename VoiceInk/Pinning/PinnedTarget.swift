import ApplicationServices
import Foundation

/// A destination that dictated text can be delivered to without the source app
/// having to be frontmost. Different kinds of destinations need different
/// delivery mechanisms, so this is a strategy enum rather than a single struct.
enum PinnedTarget {
    /// An iTerm2 session, addressed by its stable session id (e.g. "w0t0p0:ABCD1234").
    /// `sessionName` is the pane/tab title captured once at pin time, display only - see
    /// `displayLabel`. With many panes open, the app name alone cannot tell the user
    /// which one is pinned, which is what made toggling the pin the only way to check.
    case iTermSession(id: String, appName: String, sessionName: String?)

    /// A focused, text-ish accessibility element in a native app (text field, text area, combo box)
    /// that can be written directly via `kAXValueAttribute`. This is the PREFERRED AX delivery
    /// mechanism: writing a value is atomic and does not depend on where the app's internal
    /// keyboard focus happens to be at delivery time.
    ///
    /// `element` is a fast-path cache only, not a durable identity: many apps destroy and
    /// recreate their focused element as soon as focus changes anywhere, including when
    /// VoiceInk's own recorder panel appears. `pid` and `windowTitle` are what make the
    /// target re-resolvable once `element` goes stale - see `PinnedDestinationManager`'s
    /// delivery-time re-resolution.
    case axElement(element: AXUIElement, appName: String, bundleID: String, pid: pid_t, windowTitle: String?)

    /// A focused accessibility element that exists but could NOT be written via
    /// `kAXValueAttribute` (common in Electron/Chromium-based apps and various custom text
    /// controls, which frequently do not expose a settable value at all). This is the FALLBACK
    /// delivery mechanism: text is delivered as synthesized keyboard input targeted at the
    /// owning process, not written to this specific element - see
    /// `PinnedDestinationManager.deliverViaKeystrokes`. Deliberately kept as its own case rather
    /// than folded into `axElement`, since the two have genuinely different reliability
    /// characteristics: a value write lands exactly where it was pinned, while synthesized
    /// keyboard input lands wherever the destination process currently has focus internally,
    /// which may have moved since pin time. Pretending they were the same case would hide that
    /// difference from both the delivery code and anyone reading it.
    ///
    /// `element` and `windowTitle` are captured at pin time for display/liveness purposes only -
    /// unlike `axElement`, delivery never re-resolves or re-reads this specific element, since
    /// keyboard input isn't targeted at it in the first place. See `PinnedDestinationManager`'s
    /// delivery path for the (deliberately simpler) liveness check this case uses instead.
    case axKeystrokeElement(element: AXUIElement, appName: String, bundleID: String, pid: pid_t, windowTitle: String?)

    static let iTermBundleIdentifier = "com.googlecode.iterm2"

    var appName: String {
        switch self {
        case .iTermSession(_, let appName, _):
            return appName
        case .axElement(_, let appName, _, _, _):
            return appName
        case .axKeystrokeElement(_, let appName, _, _, _):
            return appName
        }
    }

    /// The bundle identifier used to look up an `EnterRule` for this target.
    var bundleIdentifier: String {
        switch self {
        case .iTermSession:
            return Self.iTermBundleIdentifier
        case .axElement(_, _, let bundleID, _, _):
            return bundleID
        case .axKeystrokeElement(_, _, let bundleID, _, _):
            return bundleID
        }
    }

    /// Longest the qualifier portion (session name / window title) of `displayLabel` is
    /// allowed to be before truncation - keeps a very long pane or window title from
    /// stretching menu bar / notification layout.
    private static let maxDisplayQualifierLength = 40

    private static func truncatedQualifier(_ text: String) -> String {
        guard text.count > maxDisplayQualifierLength else { return text }
        return "\(text.prefix(maxDisplayQualifierLength - 1))…"
    }

    /// User-facing label for this destination: the app name, plus - when available - a
    /// qualifier identifying WHICH one, since the app name alone cannot distinguish
    /// between several iTerm2 panes or windows in the same app. Falls back to the plain
    /// app name whenever no qualifier was captured or it came back empty, so this never
    /// shows a bare separator or placeholder text. Display only: never used for
    /// identity/matching (see the `==` override below), since a pane's title or a
    /// window's title can change at any time after the pin was captured.
    var displayLabel: String {
        switch self {
        case .iTermSession(_, let appName, let sessionName):
            guard let sessionName, !sessionName.isEmpty else { return appName }
            return "\(appName) – \(Self.truncatedQualifier(sessionName))"
        case .axElement(_, let appName, _, _, let windowTitle):
            guard let windowTitle, !windowTitle.isEmpty else { return appName }
            return "\(appName) – \(Self.truncatedQualifier(windowTitle))"
        case .axKeystrokeElement(_, let appName, _, _, let windowTitle):
            // Same display shape as `axElement` - the label answers "which app/window did the
            // user pin", not "which delivery mechanism will be used", so it stays uniform.
            guard let windowTitle, !windowTitle.isEmpty else { return appName }
            return "\(appName) – \(Self.truncatedQualifier(windowTitle))"
        }
    }
}

extension PinnedTarget: Equatable {
    /// Whether `rhs` refers to the same live destination as `lhs`.
    /// AXUIElement does not conform to Equatable on its own, so this compares with `CFEqual`.
    /// `pid`, `windowTitle` and `sessionName` are re-resolution/display metadata, not part
    /// of the destination's identity, so they are intentionally left out of this
    /// comparison - a pane's title changing must never look like a different pin.
    static func == (lhs: PinnedTarget, rhs: PinnedTarget) -> Bool {
        switch (lhs, rhs) {
        case (.iTermSession(let lhsID, _, _), .iTermSession(let rhsID, _, _)):
            return lhsID == rhsID
        case (.axElement(let lhsElement, _, let lhsBundleID, _, _), .axElement(let rhsElement, _, let rhsBundleID, _, _)):
            return lhsBundleID == rhsBundleID && CFEqual(lhsElement, rhsElement)
        case (
            .axKeystrokeElement(let lhsElement, _, let lhsBundleID, _, _),
            .axKeystrokeElement(let rhsElement, _, let rhsBundleID, _, _)
        ):
            return lhsBundleID == rhsBundleID && CFEqual(lhsElement, rhsElement)
        default:
            // Deliberately includes axElement vs. axKeystrokeElement of the same underlying
            // element: they are different pinned destinations by delivery mechanism, even if a
            // future AX state change made the same control writable - see the doc comment on
            // `axKeystrokeElement`.
            return false
        }
    }
}
