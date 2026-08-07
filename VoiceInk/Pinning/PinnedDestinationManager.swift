import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

/// Lets the user pin a destination (an iTerm2 session, or a focused element in any
/// other app) once, then keeps sending dictated text there without stealing focus, so
/// they can keep reading or working elsewhere while dictation continues to land in the
/// pinned spot. A focused element outside iTerm2 is delivered to via one of two
/// mechanisms depending on what the app exposes: a direct AX value write where
/// possible (preferred - see `PinnedTarget.axElement`), or synthesized keyboard input
/// as a fallback for apps that do not expose a settable value at all, such as many
/// Electron/Chromium-based apps (see `PinnedTarget.axKeystrokeElement`).
@MainActor
final class PinnedDestinationManager: ObservableObject {
    static let shared = PinnedDestinationManager()

    @Published private(set) var pinned: PinnedTarget?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PinnedDestinationManager")

    private static let textishRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    private init() {
        // A pin deliberately does NOT survive a restart: it names a live target the user
        // chose in a session that is over, and silently resurrecting it would send the
        // next dictation somewhere they are no longer looking.
        Task { [weak self] in
            await self?.restoreOrphanedITermTintIfNeeded()
        }
    }

    // MARK: - Orphaned tint recovery

    // The pin itself is not persisted, but the TINT has to be: it is a change made to
    // something outside this app, and the process that owes the user a restore can be
    // killed at any moment - crash, force quit, a rebuild during development. Without
    // this, a pane keeps a green background with nothing on screen explaining why and no
    // way to undo it short of the user hunting through iTerm2's own color settings.
    //
    // So the marking (session id plus the color captured BEFORE tinting) is written to
    // disk the moment it is applied and removed the moment it is reverted. On launch, a
    // record still present means the previous run never got to revert it, and this puts
    // the original color back.
    private enum TintPersistenceKeys {
        static let activeMarking = "PinnedDestinationITermTint"
    }

    private struct PersistedTint: Codable {
        let sessionID: String
        let red: Int
        let green: Int
        let blue: Int
    }

    private func persistActiveMarking(_ marking: (sessionID: String, previousBackgroundColor: ITermColor)?) {
        let defaults = UserDefaults.standard
        guard let marking else {
            defaults.removeObject(forKey: TintPersistenceKeys.activeMarking)
            return
        }

        let stored = PersistedTint(
            sessionID: marking.sessionID,
            red: marking.previousBackgroundColor.red,
            green: marking.previousBackgroundColor.green,
            blue: marking.previousBackgroundColor.blue
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: TintPersistenceKeys.activeMarking)
    }

    private func restoreOrphanedITermTintIfNeeded() async {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: TintPersistenceKeys.activeMarking),
            let stored = try? JSONDecoder().decode(PersistedTint.self, from: data)
        else {
            return
        }

        // Cleared first, unconditionally: if the pane is already gone the restore below
        // can never succeed, and a record that outlives its session would otherwise be
        // retried on every single launch forever.
        defaults.removeObject(forKey: TintPersistenceKeys.activeMarking)

        logger.notice("Restoring an iTerm2 background color left tinted by a previous run.")
        await restoreITermBackgroundColor(
            (
                sessionID: stored.sessionID,
                previousBackgroundColor: ITermColor(red: stored.red, green: stored.green, blue: stored.blue)
            ))
    }

    // MARK: - Hotkey toggle

    /// Pure decision table for the pin-destination shortcut, factored out of `toggle()`
    /// so the state machine is unit-testable without any live AX/AppleScript capture:
    /// - no pin yet, a destination is focused -> pin it
    /// - no pin yet, nothing pinnable is focused -> refused
    /// - pin exists, focus is on that same destination -> unpin
    /// - pin exists, focus is on a different destination -> re-pin to it
    /// - pin exists, nothing pinnable is focused -> refused (existing pin is left untouched)
    enum ToggleDecision: Equatable {
        case pin(PinnedTarget)
        case unpin
        case rePin(PinnedTarget)
        case refused
    }

    // `nonisolated` so this pure decision table can be unit-tested synchronously,
    // without hopping onto the main actor - it touches no instance state.
    nonisolated static func decideToggle(existingPin: PinnedTarget?, focusedCandidate: PinnedTarget?) -> ToggleDecision {
        guard let existingPin else {
            guard let focusedCandidate else { return .refused }
            return .pin(focusedCandidate)
        }

        guard let focusedCandidate else { return .refused }

        if existingPin == focusedCandidate {
            return .unpin
        }

        return .rePin(focusedCandidate)
    }

    // MARK: - Delivery-time re-resolution

    /// Outcome of trying to deliver to the stored pinned target: the cached AXUIElement
    /// may still be usable (fast path), or it may need re-resolving inside its owning
    /// app, or that re-resolution may fail in one of two importantly different ways -
    /// the app itself is gone (a real "the pin is dead" case), versus the app being
    /// alive but nothing currently focused there (transient - the pin stays intact).
    enum AXDeliveryResolution: Equatable {
        case useCachedElement
        case useReResolvedElement
        case reportGone
        case reportNothingFocused
    }

    /// Pure decision table, mirroring `decideToggle`: given what is already known about
    /// the cached element, the owning app, and whether re-resolution found something,
    /// picks the outcome. `nonisolated` so it needs no live AX/app state to unit-test.
    nonisolated static func decideAXDeliveryResolution(
        cachedElementAlive: Bool,
        appAlive: Bool,
        reResolvedElementPresent: Bool
    ) -> AXDeliveryResolution {
        if cachedElementAlive { return .useCachedElement }
        guard appAlive else { return .reportGone }
        return reResolvedElementPresent ? .useReResolvedElement : .reportNothingFocused
    }

    /// Toggle behavior for the pin-destination shortcut. Every outcome posts a
    /// user-visible notification. See `decideToggle` for the state machine.
    func toggle() async {
        let capture = await captureFocusedTarget()

        let focusedCandidate: PinnedTarget?
        if case .candidate(let target) = capture {
            focusedCandidate = target
        } else {
            focusedCandidate = nil
        }

        let decision = Self.decideToggle(existingPin: pinned, focusedCandidate: focusedCandidate)

        switch decision {
        case .pin(let target), .rePin(let target):
            // Whatever was marked for the PREVIOUS pin (if any - `.pin` never has one, `.rePin`
            // might) must be cleared before the new one is established, so a stale badge never
            // survives a re-pin onto a different session. See `clearActiveITermMarkingIfNeeded`.
            clearActiveITermMarkingIfNeeded()
            setPin(target)
            if case .iTermSession(let id, _, _) = target {
                // Fire-and-forget: marking is a nicety, never a precondition for the pin
                // itself, which has already succeeded by the time this runs (see `setPin`
                // above). Never awaited here, so a slow or failing AppleScript round-trip to
                // iTerm2 cannot delay the "Pinned to %@" notification the user already saw.
                Task { [weak self] in
                    await self?.markITermSessionPinned(id: id)
                }
            }
        case .unpin:
            unpin(notify: true)
        case .refused:
            if case .permissionDenied(let appName) = capture {
                // A destination may well be focused - VoiceInk just could not ask, so
                // the generic "nothing is focused" hint below would be actively wrong.
                // Only the app name is known at this point - permission was denied
                // before VoiceInk could learn anything more specific (e.g. a session name).
                reportPermissionDenied(destinationLabel: appName)
            } else {
                // Deliberately names no particular app: VoiceInk can pin a focused element in
                // most apps (an iTerm2 session, a native text field, or - via synthesized
                // keyboard input - many apps that don't expose a settable text value at all),
                // and naming iTerm2 here previously read as "this only works in iTerm2", which
                // is not true and was actively misleading users away from trying it elsewhere.
                NotificationManager.shared.showNotification(
                    title: String(localized: "Focus something you can type into, then use this shortcut to pin it"),
                    type: .warning
                )
            }
        }
    }

    private func setPin(_ target: PinnedTarget) {
        pinned = target

        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Pinned to %@"), target.displayLabel),
            type: .success
        )
    }

    /// Unpin, optionally showing a notification. Manual unpins (hotkey, menu bar) notify;
    /// internal callers that already show a more specific message pass `notify: false`.
    func unpin(notify: Bool) {
        clearActiveITermMarkingIfNeeded()
        guard let target = pinned else { return }
        pinned = nil

        guard notify else { return }
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Unpinned %@"), target.displayLabel),
            type: .info
        )
    }

    // MARK: - Capturing a pin

    /// Outcome of looking for something pinnable at the current focus. Kept distinct
    /// from a plain `PinnedTarget?` so `toggle()` can tell "nothing is focused" (show
    /// the generic hint) apart from "an iTerm2 session may well be focused, but
    /// VoiceInk cannot ask because Automation permission is missing" (show the
    /// permission hint instead) - the two would otherwise both collapse to nil and
    /// produce the wrong message.
    private enum FocusCapture {
        case candidate(PinnedTarget)
        case permissionDenied(appName: String)
        case none
    }

    private func captureFocusedTarget() async -> FocusCapture {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.bundleIdentifier == PinnedTarget.iTermBundleIdentifier
        {
            return await captureITermSession(appName: frontmost.localizedName ?? "iTerm2")
        }

        if let target = captureAXFocusedElement() {
            return .candidate(target)
        }
        return .none
    }

    private func captureITermSession(appName: String) async -> FocusCapture {
        // Captures id and name together, in the same script, off the SAME direct
        // reference to "current session of current tab of current window" - never
        // addressed by id, so this cannot hit the "session id ..." specifier failure
        // that the enumerate-and-compare pattern elsewhere in this file exists to work
        // around. That pattern only becomes necessary once a session has to be
        // re-located FROM a previously stored id (liveness, delivery below); capturing
        // the display name here, at the moment the session is already directly in
        // hand, needs none of that. `linefeed` (an AppleScript keyword, not a raw byte
        // in the script source) joins the two values in the RESULT string only -
        // unrelated to the raw-newline-in-a-string-literal hazard `appleScriptTextLiteral`
        // guards against below, which is about text embedded back into script source.
        let script = """
            tell application "iTerm2"
                try
                    set targetSession to current session of current tab of current window
                    return (id of targetSession) & linefeed & (name of targetSession)
                on error
                    return ""
                end try
            end tell
            """

        switch await runAppleScript(script) {
        case .success(let combined):
            guard let combined, !combined.isEmpty else { return .none }
            let identity = Self.splitSessionIdentity(combined)
            guard !identity.id.isEmpty else { return .none }
            return .candidate(.iTermSession(id: identity.id, appName: appName, sessionName: identity.name))
        case .permissionDenied:
            return .permissionDenied(appName: appName)
        case .failed:
            return .none
        }
    }

    /// Splits the `id<linefeed>name` string produced by `captureITermSession`'s script.
    /// Only the FIRST linefeed is treated as the separator, so an (unlikely) embedded
    /// newline in the session's own name just becomes part of the name rather than
    /// corrupting the split. `nonisolated static` so this pure parser is unit-testable
    /// synchronously, same as the other builders/parsers in this file.
    nonisolated static func splitSessionIdentity(_ combined: String) -> (id: String, name: String?) {
        guard let separatorRange = combined.range(of: "\n") else { return (combined, nil) }
        let id = String(combined[combined.startIndex..<separatorRange.lowerBound])
        let name = String(combined[separatorRange.upperBound...])
        return (id, name.isEmpty ? nil : name)
    }

    // NOTE: AXUIElementCreateSystemWide() + kAXFocusedUIElementAttribute was tried
    // first and does not work - it returns .cannotComplete with no element even when
    // a text area is genuinely focused. The per-application accessibility object
    // (AXUIElementCreateApplication(pid) for the frontmost app) is what actually
    // returns the focused element. Verified against a live target - do not change
    // back to the system-wide element without re-verifying.
    private func captureAXFocusedElement() -> PinnedTarget? {
        guard AXIsProcessTrusted() else { return nil }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            let bundleID = frontmost.bundleIdentifier
        else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        guard let (element, mechanism) = focusedElement(of: axApp) else { return nil }

        let appName = frontmost.localizedName ?? bundleID
        let pid = frontmost.processIdentifier
        let windowTitle = windowTitle(of: element)

        switch mechanism {
        case .axValueWrite:
            return .axElement(element: element, appName: appName, bundleID: bundleID, pid: pid, windowTitle: windowTitle)
        case .keystrokeInjection:
            return .axKeystrokeElement(
                element: element, appName: appName, bundleID: bundleID, pid: pid, windowTitle: windowTitle)
        }
    }

    /// Which of the two AX delivery mechanisms a captured focused element should use. Pure
    /// decision table, mirroring `decideToggle` / `decideAXDeliveryResolution`: a settable value
    /// attribute wins whenever it's available (see `PinnedTarget.axElement`'s doc comment for
    /// why it's preferred), and the keystroke-injection fallback (see
    /// `PinnedTarget.axKeystrokeElement`) is used for everything else - deliberately NOT
    /// additionally gated on `isTextishRole`, since the entire point of the fallback is to
    /// still allow pinning controls (most commonly in Electron/Chromium-based apps) that don't
    /// expose a settable value OR a role VoiceInk recognizes at all. The worst case of pinning
    /// something that turns out not to be a text control is a delivery that lands nowhere
    /// useful - a failed delivery, not data loss or corruption - which is an acceptable trade
    /// for not narrowing the feature back down to a role whitelist. `nonisolated` so this pure
    /// lookup is unit-testable synchronously, same as the other decision tables in this file.
    nonisolated static func decideDeliveryMechanism(
        isValueSettable: Bool,
        isTextishRole: Bool
    ) -> FocusedElementDeliveryMechanism {
        (isValueSettable && isTextishRole) ? .axValueWrite : .keystrokeInjection
    }

    /// Which AX delivery mechanism a `PinnedTarget` captured from a focused element should use.
    /// See the doc comments on `PinnedTarget.axElement` / `.axKeystrokeElement` for what each
    /// one means for delivery reliability.
    enum FocusedElementDeliveryMechanism: Equatable {
        case axValueWrite
        case keystrokeInjection
    }

    /// Reads `kAXFocusedUIElementAttribute` off an application element and classifies which
    /// delivery mechanism it needs (see `decideDeliveryMechanism`). Shared between the initial
    /// pin capture (which accepts either mechanism) and delivery-time re-resolution for an
    /// already-pinned `axElement` (which only accepts a fresh `.axValueWrite` result - see
    /// `reResolveAXElement` - since re-resolving a value-write pin into a keystroke-only one
    /// mid-delivery would silently change the target's delivery mechanism without that change
    /// being represented anywhere).
    private func focusedElement(of axApp: AXUIElement) -> (element: AXUIElement, mechanism: FocusedElementDeliveryMechanism)? {
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
                == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = focusedRef as! AXUIElement

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        // An unreadable/missing role does NOT count against the element - it stays a secondary
        // sanity filter only, same as before this fallback existed: many custom controls (again,
        // Electron/Chromium apps in particular) don't expose a role VoiceInk recognizes at all,
        // and that is exactly the case the keystroke fallback exists to still allow.
        let isTextishRole = (roleRef as? String).map { Self.textishRoles.contains($0) } ?? true

        let mechanism = Self.decideDeliveryMechanism(isValueSettable: isSettable.boolValue, isTextishRole: isTextishRole)
        return (element, mechanism)
    }

    /// Best-effort title of the AXWindow containing `element`, used only as a soft
    /// disambiguator when re-resolving a pin after its cached element has gone stale.
    private func windowTitle(of element: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
            let windowRef,
            CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        var titleRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
                == .success
        else {
            return nil
        }

        return titleRef as? String
    }

    // MARK: - Delivery

    /// Delivers `text` to the pinned destination, if any. Verifies liveness first;
    /// if the destination is confirmed gone, clears the pin, notifies the user that
    /// delivery did NOT happen, and returns false. If VoiceInk lacks Automation
    /// permission to even ask, the pin is left untouched - that is not evidence the
    /// destination is gone, see the "iTerm2 delivery" section below. Never fails
    /// silently, since by definition the user is looking elsewhere while this runs.
    @discardableResult
    func deliver(text: String) async -> Bool {
        guard let target = pinned else { return false }

        switch target {
        case .iTermSession(let id, _, _):
            switch await iTermSessionLiveness(id: id) {
            case .success(let status) where status == "alive":
                return await finishDelivery(to: target, rawText: text)
            case .success:
                reportGone(target)
                return false
            case .permissionDenied:
                reportPermissionDenied(destinationLabel: target.displayLabel)
                return false
            case .failed:
                reportGone(target)
                return false
            }

        case .axElement(let element, let appName, let bundleID, let pid, let windowTitle):
            let cachedAlive = isAXElementAlive(element)
            let appAlive = !cachedAlive && isAppAlive(pid: pid)
            // Only pay for a re-resolution round-trip when the fast path is actually dead.
            let reResolved: AXUIElement? =
                (!cachedAlive && appAlive) ? reResolveAXElement(pid: pid, expectedWindowTitle: windowTitle) : nil

            switch Self.decideAXDeliveryResolution(
                cachedElementAlive: cachedAlive,
                appAlive: appAlive,
                reResolvedElementPresent: reResolved != nil
            ) {
            case .useCachedElement:
                return await finishDelivery(to: target, rawText: text)

            case .useReResolvedElement:
                guard let reResolved else { return false }
                let reResolvedTarget = PinnedTarget.axElement(
                    element: reResolved, appName: appName, bundleID: bundleID, pid: pid, windowTitle: windowTitle)
                // Cache the freshly resolved element so the next delivery can use the fast path again.
                pinned = reResolvedTarget
                return await finishDelivery(to: reResolvedTarget, rawText: text)

            case .reportGone:
                reportGone(target)
                return false

            case .reportNothingFocused:
                // The app is still there, just not focused on anything right now - unlike
                // "gone", this is transient, so the pin itself is left untouched.
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "Nothing is focused in %@ right now. Text was not delivered."),
                        appName),
                    type: .warning
                )
                return false
            }

        case .axKeystrokeElement(_, _, _, let pid, _):
            // Deliberately simpler than the `.axElement` liveness dance above: keystroke
            // delivery is never targeted at the specific captured element in the first place
            // (see `PinnedTarget.axKeystrokeElement`'s doc comment), so there is nothing to
            // re-resolve - it always goes to whatever the destination process currently has
            // focus on internally. The only thing worth checking first is whether that process
            // still exists at all.
            guard isAppAlive(pid: pid) else {
                reportGone(target)
                return false
            }
            return await finishDelivery(to: target, rawText: text)
        }
    }

    private func finishDelivery(to target: PinnedTarget, rawText: String) async -> Bool {
        let rules = PinnedDestinationEnterRulesManager.shared
        let appendReturn = rules.appendReturn(forBundleIdentifier: target.bundleIdentifier)
        let text = PinnedDestinationEnterRuleStore.deliveredText(
            rawText,
            appendReturn: appendReturn,
            appendSpace: rules.appendSpace(forBundleIdentifier: target.bundleIdentifier)
        )
        // Never logs the dictated text itself - only routing metadata. This line exists
        // because "text arrived but Return did not" is invisible from the outside: every
        // step can succeed while appendReturn quietly resolves to false, and only this
        // log can tell those cases apart after the fact.
        logger.notice(
            "Pinned delivery: label=\(target.displayLabel, privacy: .public) bundleID=\(target.bundleIdentifier, privacy: .public) appendReturn=\(appendReturn, privacy: .public) knownRules=\(rules.rules.map { "\($0.bundleIdentifier):\($0.appendReturn ? "return" : "insert")" }.joined(separator: ","), privacy: .public)"
        )

        switch target {
        case .iTermSession(let id, _, _):
            // The insert-mode prefix only makes sense for the iTerm path - it exists to
            // work around modal terminal UIs, which is not a concept that applies to an
            // arbitrary Accessibility text field.
            let sendInsertPrefix = rules.sendInsertPrefix(forBundleIdentifier: target.bundleIdentifier)
            switch await deliverToITermSession(
                id: id, text: text, appendReturn: appendReturn, sendInsertPrefix: sendInsertPrefix)
            {
            case .delivered:
                return true
            case .deliveredWithoutSubmission:
                // Mirrors the AX path: the transcript itself already landed by the time
                // the separate submit write failed (or the session vanished between the
                // text write and the submit write - a real race now that they are two
                // genuinely separate AppleScript executions) - that is not "nothing was
                // delivered", so the pin stays intact and this is not reported as an error.
                reportDeliveredWithoutSubmission(target)
                return true
            case .gone:
                reportGone(target)
                return false
            case .permissionDenied:
                reportPermissionDenied(destinationLabel: target.displayLabel)
                return false
            case .failed:
                reportDeliveryFailed(target)
                return false
            }

        case .axElement(let element, _, _, let pid, _):
            switch deliverToAXElement(element: element, pid: pid, text: text, appendReturn: appendReturn) {
            case .delivered:
                return true
            case .deliveredWithoutSubmission:
                // The transcript itself landed - that is the part the user cares most
                // about not losing - so this is not a failure and the pin stays intact.
                // Only the (best-effort) submit step didn't work.
                reportDeliveredWithoutSubmission(target)
                return true
            case .writeFailed:
                reportDeliveryFailed(target)
                return false
            }

        case .axKeystrokeElement(_, _, _, let pid, _):
            switch deliverViaKeystrokes(pid: pid, text: text, appendReturn: appendReturn) {
            case .delivered:
                return true
            case .deliveredWithoutSubmission:
                // Same reasoning as the `.axElement` case above: the text itself was typed
                // successfully, only the best-effort submit keystroke could not be confirmed.
                reportDeliveredWithoutSubmission(target)
                return true
            case .writeFailed:
                reportDeliveryFailed(target)
                return false
            }
        }
    }

    private func reportGone(_ target: PinnedTarget) {
        clearActiveITermMarkingIfNeeded()
        pinned = nil

        NotificationManager.shared.showNotification(
            title: String(
                format: String(localized: "Pinned destination (%@) is gone. Text was not delivered."),
                target.displayLabel),
            type: .error
        )
    }

    /// Reports an Automation-permission failure without touching the pin: unlike
    /// `reportGone`, this is not evidence the destination has disappeared - only that
    /// VoiceInk cannot currently prove either way - so discarding the pin here would
    /// be actively wrong, and would keep happening on every rebuild, since Automation
    /// consent is keyed to the app's code signature. Wording stays short, actionable,
    /// and free of error codes, since the fix is a System Settings toggle, not
    /// something the user can debug. `destinationLabel` is a plain app name when
    /// permission was denied before VoiceInk could learn anything more specific, or the
    /// fuller `PinnedTarget.displayLabel` once a target is already known.
    private func reportPermissionDenied(destinationLabel: String) {
        NotificationManager.shared.showNotification(
            title: String(
                format: String(
                    localized: "VoiceInk needs permission to control %@. Grant access in System Settings → Privacy & Security → Automation."
                ),
                destinationLabel),
            type: .error
        )
    }

    private func reportDeliveryFailed(_ target: PinnedTarget) {
        clearActiveITermMarkingIfNeeded()
        pinned = nil

        NotificationManager.shared.showNotification(
            title: String(
                format: String(localized: "Could not deliver to pinned destination (%@). Text was not delivered."),
                target.displayLabel),
            type: .error
        )
    }

    /// The dictated text was written successfully but the follow-up submit step could
    /// not be confirmed: for the AX path, no usable Accessibility action and the
    /// synthetic key event either wasn't possible or wasn't confirmed; for the iTerm2
    /// path, the separate submit write failed or the session vanished between the text
    /// write and the submit write. Either way, the pin is left untouched - submission
    /// failing says nothing about whether the destination is still there - and this must
    /// never be reported as a plain success either, since the user's message may now be
    /// sitting unsent in the destination's input field.
    private func reportDeliveredWithoutSubmission(_ target: PinnedTarget) {
        NotificationManager.shared.showNotification(
            title: String(
                format: String(
                    localized: "Delivered to %@, but could not submit automatically. You may need to press Return yourself."
                ),
                target.displayLabel),
            type: .warning
        )
    }

    private func isAppAlive(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    /// Re-resolves a live, writable, text-ish focused element inside the still-running
    /// app identified by `pid`. The cached AXUIElement from pin time is gone - most apps
    /// recreate their focused element whenever focus moves anywhere, and VoiceInk's own
    /// recorder panel appearing is enough to trigger that - so this asks the app fresh for
    /// whatever it currently considers focused, applying the same suitability gate used at
    /// pin time. `expectedWindowTitle` is a soft preference only: a mismatch does not
    /// disqualify the result, since best-effort delivery beats refusing to deliver over a
    /// title change the user has no way to fix.
    private func reResolveAXElement(pid: pid_t, expectedWindowTitle: String?) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        // Only a fresh `.axValueWrite` result is acceptable here - this re-resolution exists
        // specifically for a stale `axElement` (value-write) pin; if the currently focused
        // element in this app can now only be reached via keystroke injection, that is not a
        // usable replacement for a value-write pin (see the doc comment on `focusedElement`).
        guard let (element, mechanism) = focusedElement(of: axApp), mechanism == .axValueWrite else { return nil }

        if let expectedWindowTitle, windowTitle(of: element) != expectedWindowTitle {
            logger.notice("Re-resolved pinned element in a different window than the one pinned; using it anyway.")
        }

        return element
    }

    // MARK: - Liveness

    /// Confirms the pinned iTerm2 session id still exists before attempting delivery.
    /// iTerm2's scripting dictionary has no top-level "session id" object specifier -
    /// addressing one directly (e.g. `session id "..."`) always raises an AppleScript
    /// error regardless of whether the session exists, which used to make every
    /// liveness check fail and misreport a live session as gone. Sessions only exist
    /// nested under tabs under windows, so finding one means enumerating down to it.
    private func iTermSessionLiveness(id: String) async -> AppleScriptOutcome {
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is "\(Self.escapedForAppleScript(id))" then
                                return "alive"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "dead"
            end tell
            """
        return await runAppleScript(script)
    }

    // Verified: while the target is alive, AX reads/writes return .success; once its
    // window is closed, they return .invalidUIElement unambiguously. .cannotComplete
    // is NOT a reliable dead signal on its own (it also appears in non-fatal
    // situations), so only .invalidUIElement clears the pin here.
    private func isAXElementAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return status != .invalidUIElement
    }

    // MARK: - iTerm2 delivery

    // HOW SUBMISSION WORKS. Measured at the pty byte level against a live session
    // reading in raw mode, 2026-08-07 - all three of these were verified directly, and
    // the conclusions are not theory:
    //
    // 1. A synthetic Return key event posted to iTerm2's process via
    //    `CGEvent.postToPid` produces NO pty bytes at all. Accessibility was granted
    //    and the post itself reported success - iTerm2 simply does not act on events
    //    delivered that way. Any submit built on it is silently a no-op, which is
    //    especially dangerous because the post "succeeding" reads as delivery.
    //    Do not reintroduce a key-event submit for iTerm2.
    //
    // 2. Concatenating the CR into the text write - `("<text>" & return)` - delivers
    //    the whole thing as ONE read: `b'TESTB\r'`. That is exactly the shape a TUI's
    //    paste heuristic classifies as pasted content, and pasted content containing a
    //    CR becomes a LINE BREAK, not a submission. Short strings often slip under the
    //    heuristic and do submit, which is why this form appears to work until a
    //    longer dictation silently turns into a newline instead.
    //
    // 3. Issuing the CR as its OWN separate `write text return` call, after the text
    //    write has completed, delivers `b'\r'` alone in its own read. A single byte
    //    cannot trip any paste heuristic, so it is read as a keypress and submits.
    //    This is the mechanism used below.
    //
    // `newline no` matters throughout: `newline yes` emits a line feed, which a shell
    // would execute but a raw-mode TUI does not treat as submit.

    // Settle gap between the text write completing and the submit step. Mirrors the
    // empirically derived delay of this app's pre-existing AutoEnter feature
    // (`TranscriptionDelivery.paste` - 100ms proved too short for terminal emulators,
    // 500ms is the value that has held up).
    private static let submitDelaySeconds: Double = 0.5

    // Settle delay between the insert-mode prefix write and the text write that
    // follows it. Unlike `submitDelaySeconds`, there is no existing empirically
    // validated figure for this particular gap to reuse: entering insert mode is a
    // single, effectively synchronous keystroke, not something that needs to wait out
    // a paste-processing window the way a large block of dictated text does. This is a
    // reasoned judgement call, not a proven value - it only needs to be enough that the
    // two separate `write text` calls are not read by the destination as one burst.
    private static let insertModeSettleDelaySeconds: Double = 0.1

    /// The insert-mode prefix: the letter `i`, immediately followed by a DEL (0x7F, what the
    /// Delete/Backspace key sends). This pair is self-cancelling in BOTH starting states, which
    /// is the whole point - VoiceInk cannot ask a modal TUI which mode it is currently in:
    ///
    /// - Starting in NORMAL mode, `i` switches to insert mode and is consumed as a command, so
    ///   nothing is typed; the DEL then deletes from an empty position and does nothing.
    /// - Starting in INSERT mode already, `i` is typed as a literal character; the DEL then
    ///   deletes exactly that character.
    ///
    /// Either way the destination ends up in insert mode with an unchanged buffer. Sending the
    /// bare `i` alone - which this used to do - left a stray literal `i` in front of every
    /// dictation whenever the target was already in insert mode. `character id 127` produces
    /// the DEL byte from AppleScript without embedding a raw control character in the script
    /// source.
    private static let insertModePrefixStatement = "write text (\"i\" & (character id 127)) newline no"

    /// One step of an iTerm2 delivery sequence. Kept as data - not executed inline - so
    /// the ORDER and ROLE of each write is unit-testable without any live AppleScript
    /// or iTerm2 state; see `iTermDeliverySteps` and `decideITermDeliveryOutcome` below.
    struct ITermDeliveryStep: Equatable {
        enum Role: Equatable {
            case insertModePrefix
            case text
            case submit
        }

        let statement: String
        let role: Role
        /// Seconds to wait AFTER this step succeeds and BEFORE the next one is sent.
        /// Zero for the final step in the sequence.
        let settleDelaySeconds: Double
    }

    /// Builds the ordered, role-tagged WRITE steps for delivering to an iTerm2
    /// session: an optional insert-mode prefix as its own write, then the transcript.
    /// Deliberately NEVER includes a submitting carriage return - submission is not a
    /// write step at all but its own mechanism decided at submit time (see
    /// `decideITermSubmitPlan` and the comment block above for why pty CR bytes cannot
    /// reliably submit). `nonisolated static` so this pure sequencing builder is
    /// unit-testable synchronously, same as the other builders in this file.
    nonisolated static func iTermDeliverySteps(
        textLiteral: String,
        sendInsertPrefix: Bool
    ) -> [ITermDeliveryStep] {
        var steps: [ITermDeliveryStep] = []

        if sendInsertPrefix {
            steps.append(
                ITermDeliveryStep(
                    statement: insertModePrefixStatement,
                    role: .insertModePrefix,
                    settleDelaySeconds: insertModeSettleDelaySeconds
                ))
        }

        steps.append(
            ITermDeliveryStep(
                statement: "write text \(textLiteral) newline no",
                role: .text,
                settleDelaySeconds: 0
            ))

        return steps
    }


    /// Coarse classification of what a single delivery step accomplished, collapsing
    /// `AppleScriptOutcome`'s cases (including the script's own "gone"/"error" result
    /// strings, distinguished from a genuine `.success("ok")`) into one pure enum.
    /// `nonisolated static` so this lookup is unit-testable synchronously, mirroring
    /// `classifyAppleScriptError` above.
    enum ITermWriteResult: Equatable {
        case ok
        case gone
        case permissionDenied
        case failed
    }

    nonisolated static func classifyITermWriteOutcome(_ outcome: AppleScriptOutcome) -> ITermWriteResult {
        switch outcome {
        case .success(let result) where result == "ok":
            return .ok
        case .success:
            // Either the enumeration completed without finding the session id (it
            // disappeared between the previous step, or the liveness check, and this
            // write - a narrow but now genuinely real race between separate writes),
            // or the write itself raised inside the session's own `try` block. Both
            // are treated the same way a single-write delivery already treated them.
            return .gone
        case .permissionDenied:
            return .permissionDenied
        case .failed:
            return .failed
        }
    }

    /// Outcome of a full iTerm2 delivery sequence, mirroring the AX path's
    /// `AXDeliveryWriteOutcome`: once the transcript TEXT write has succeeded, a later
    /// failure on the (now separate) submit write must not be reported as "nothing was
    /// delivered" - the transcript already landed by then.
    enum ITermDeliveryOutcome: Equatable {
        case delivered
        case deliveredWithoutSubmission
        case gone
        case permissionDenied
        case failed
    }

    /// Reduces the per-step results of a delivery sequence to one overall outcome. Pure
    /// decision table, mirroring `decideAXSubmission`: only ROLE and RESULT of each step
    /// are needed, which is what makes it testable without any live AppleScript state.
    /// A failure on `.insertModePrefix` or `.text` aborts the whole delivery with that
    /// failure's kind - nothing has reached the destination yet. A failure on `.submit`
    /// downgrades to `.deliveredWithoutSubmission` instead, since the text already has.
    nonisolated static func decideITermDeliveryOutcome(
        stepResults: [(role: ITermDeliveryStep.Role, result: ITermWriteResult)]
    ) -> ITermDeliveryOutcome {
        for (role, result) in stepResults {
            switch role {
            case .insertModePrefix, .text:
                switch result {
                case .ok: continue
                case .gone: return .gone
                case .permissionDenied: return .permissionDenied
                case .failed: return .failed
                }
            case .submit:
                return result == .ok ? .delivered : .deliveredWithoutSubmission
            }
        }
        // Every requested step (which may have been text-only, with no submit
        // requested at all) completed successfully.
        return .delivered
    }

    // Like the liveness probe above, this cannot address a session by `session id
    // "..."` directly - iTerm2 has no such top-level specifier, and doing so always
    // fails, which used to be misreported as delivery failure (and a dead pin) on
    // every single send. Each step re-locates the session the same way: by enumerating
    // windows/tabs/sessions and comparing ids. Falling through every loop without a
    // match means the session is genuinely gone, not merely unreachable.
    private func writeToITermSession(id: String, statement: String) async -> AppleScriptOutcome {
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is "\(Self.escapedForAppleScript(id))" then
                                try
                                    tell s to \(statement)
                                    return "ok"
                                on error
                                    return "error"
                                end try
                            end if
                        end repeat
                    end repeat
                end repeat
                return "gone"
            end tell
            """
        return await runAppleScript(script)
    }

    /// Runs the sequence built by `iTermDeliverySteps` as genuinely separate,
    /// sequentially awaited AppleScript executions - never concatenated into one
    /// `write text` call, and never batched into one script with an embedded `delay`.
    /// Both of those would put multiple pieces inside the same iTerm2 paste operation,
    /// which is exactly what made submission unreliable in the first place (see the
    /// comment above `submitDelaySeconds`). This mirrors the proven pattern already
    /// used by this app's non-pinned AutoEnter feature - await the previous action
    /// actually completing, sleep, THEN perform the next action as a wholly separate
    /// operation - rather than inventing new timing for a closely related problem.
    private func deliverToITermSession(
        id: String,
        text: String,
        appendReturn: Bool,
        sendInsertPrefix: Bool
    ) async -> ITermDeliveryOutcome {
        let textLiteral = Self.appleScriptTextLiteral(for: text)
        let steps = Self.iTermDeliverySteps(textLiteral: textLiteral, sendInsertPrefix: sendInsertPrefix)

        var stepResults: [(role: ITermDeliveryStep.Role, result: ITermWriteResult)] = []

        for step in steps {
            let outcome = await writeToITermSession(id: id, statement: step.statement)
            let result = Self.classifyITermWriteOutcome(outcome)
            stepResults.append((step.role, result))
            // Role and result only - the statement embeds the dictated text.
            logger.notice(
                "iTerm delivery step role=\(String(describing: step.role), privacy: .public) result=\(String(describing: result), privacy: .public)"
            )

            // Stop as soon as a step didn't unambiguously succeed - there is no reason
            // to send the next piece to a session that just reported itself gone,
            // permission-denied, or failed, and `decideITermDeliveryOutcome` only needs
            // the results collected up to (and including) that first step to conclude.
            guard result == .ok else { break }

            if step.settleDelaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(step.settleDelaySeconds * 1_000_000_000))
            }
        }

        let writesSucceeded = stepResults.allSatisfy { $0.result == .ok }
        if appendReturn, writesSucceeded {
            try? await Task.sleep(nanoseconds: UInt64(Self.submitDelaySeconds * 1_000_000_000))
            let submitResult = await submitToITermSession(id: id)
            stepResults.append((.submit, submitResult))
        }

        return Self.decideITermDeliveryOutcome(stepResults: stepResults)
    }

    /// Submits (presses Return in) the pinned session once its text has landed, by
    /// writing the CR as its own separate `write text` call so it reaches the pty as a
    /// lone `\r` in its own read - the only form measured to submit reliably rather
    /// than being absorbed as pasted content. See point 3 of the section comment above.
    /// Always addressed to the pinned session id, so it can never land in another pane.
    private func submitToITermSession(id: String) async -> ITermWriteResult {
        let result = Self.classifyITermWriteOutcome(
            await writeToITermSession(id: id, statement: "write text return newline no"))
        logger.notice("iTerm submit via separate CR write result=\(String(describing: result), privacy: .public)")
        return result
    }

    // MARK: - iTerm2 session marking (background tint)

    // With many panes open, the notification and menu-bar-icon backdrop tell the user THAT
    // something is pinned, but not WHICH pane - they still have to hunt for it. This tints the
    // pinned session's background so it is identifiable at a glance, entirely opt-in (see
    // `PinnedDestinationSettingsKeys.highlightPinnedITermSession`) and always reverted: on
    // explicit unpin, on re-pinning to a different target, and (best-effort) when the pin
    // self-clears because the session died.
    //
    // MECHANISM: a session's `background color` is directly readable and writable over
    // AppleScript as an RGB triple of 16-bit components. Verified against a live session -
    // reading returns the current value, writing takes effect immediately, and writing the
    // captured value back restores the original exactly.
    //
    // WHY A TINT RATHER THAN A BADGE: a badge was implemented first and removed. iTerm2's
    // badge TEXT cannot be set over AppleScript at all - only a user-defined variable can be,
    // and the badge then shows that variable ONLY if the user has already put it in their
    // profile's Badge Text field. For anyone who has not, the toggle is silently a no-op, which
    // is exactly how it behaved in practice. A background tint needs no profile setup and is
    // impossible to miss.
    //
    // THE RISK THIS ACCEPTS: unlike a badge, this touches the user's actual color scheme, so a
    // tint left behind (VoiceInk killed mid-pin, say) looks like the terminal broke rather than
    // like a leftover marker. Two things bound that: the original color is captured BEFORE the
    // tint is applied and restored verbatim on every path that ends a pin, and the tint is never
    // applied at all unless that capture succeeded - see `markITermSessionPinned`. Restoring a
    // color VoiceInk never read would be a worse outcome than not tinting in the first place.

    /// Fallback background color applied to a pinned session, as iTerm2's 16-bit RGB components,
    /// used whenever `PinnedDestinationSettingsKeys.pinnedITermTintColorHex` is missing or fails
    /// to parse (see `pinnedTintColor()`) - and, via `hexString(fromITermColor:)`, to seed that
    /// preference's registered default (see `AppDefaults.registerDefaults`), so anyone who never
    /// opens the color picker still gets this color. A deep, desaturated green - the same signal
    /// as the menu bar icon's green backdrop, not an unrelated color. Kept DARK rather than pale
    /// on purpose: this sits behind the user's real terminal content for as long as the pin
    /// lasts, and terminal schemes are overwhelmingly light text on a dark background, so a pale
    /// tint inverts the contrast the scheme was built around and makes the pane hard to read.
    /// Dark enough to leave light foreground text legible, green enough to be unmistakable next
    /// to an untinted pane. `nonisolated` so it (and the hex conversion built on it) can be read
    /// from `AppDefaults.registerDefaults`, which runs before the app is necessarily on the main
    /// actor.
    nonisolated static let defaultPinnedBackgroundColor = ITermColor(red: 1500, green: 9000, blue: 4500)

    /// The color (and opacity) to apply to a pinned session's background: the user's stored
    /// preference if present and parseable, otherwise `defaultPinnedBackgroundColor` at full
    /// opacity. Never crashes and never applies garbage - a malformed or missing preference
    /// silently falls back rather than tinting the user's terminal with whatever
    /// `itermColor(fromHexString:)` happened to produce from bad input (which is nil, not a
    /// garbage color, but the fallback here is what actually keeps `markITermSessionPinned` from
    /// having to special-case that).
    private func pinnedTintColor() -> ITermTintColor {
        guard
            let hex = UserDefaults.standard.string(forKey: PinnedDestinationSettingsKeys.pinnedITermTintColorHex),
            let tint = Self.itermColor(fromHexString: hex)
        else {
            return ITermTintColor(color: Self.defaultPinnedBackgroundColor, alpha: 1.0)
        }
        return tint
    }

    /// An 8-bit color channel (0...255, what both hex strings and SwiftUI's `Color` use) scales
    /// up to iTerm2's 16-bit component (0...65535) by multiplying by 257, NOT by 256 or by
    /// bit-shifting left 8. 255 * 257 = 65535 exactly - the full range top maps to the full range
    /// top. The tempting-looking `<< 8` (equivalent to * 256) instead tops out at 65280, which is
    /// off-white rather than white and, worse, is never wrong enough to look obviously broken -
    /// it just quietly desaturates every color pulled through it. 257 is exactly 65535 / 255.
    nonisolated private static let componentScale16From8 = 257

    /// Parses a 6-digit "RRGGBB" or 8-digit "RRGGBBAA" hex string (an optional leading "#" is
    /// accepted) into iTerm2's 16-bit RGB components plus the opacity to blend that color at (see
    /// `ITermTintColor`), applying the *257 upscale documented on `componentScale16From8` to the
    /// RGB portion. The 6-digit form is kept accepting on its own - not merely as a historical
    /// compatibility shim - because it is exactly what's already sitting in every existing stored
    /// preference and in the registered default: it always means fully opaque (alpha 1.0), same
    /// as the tint always was before opacity existed as a concept. Returns nil for anything else -
    /// wrong length, non-hex characters, empty input - rather than guessing, mirroring
    /// `parseITermColor`'s same refusal-over-guessing stance just above. `nonisolated static` so
    /// this pure parser is unit-testable synchronously, same as the other parsers in this file.
    nonisolated static func itermColor(fromHexString hex: String) -> ITermTintColor? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }

        switch digits.count {
        case 6:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            return ITermTintColor(color: color(fromRGB24: value), alpha: 1.0)
        case 8:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            let alphaComponent = Int(value & 0xFF)
            return ITermTintColor(color: color(fromRGB24: value >> 8), alpha: Double(alphaComponent) / 255.0)
        default:
            return nil
        }
    }

    /// Shared by both branches of `itermColor(fromHexString:)`: unpacks a 24-bit 0xRRGGBB value
    /// into iTerm2's upscaled 16-bit components.
    private nonisolated static func color(fromRGB24 value: UInt32) -> ITermColor {
        let red = Int((value >> 16) & 0xFF)
        let green = Int((value >> 8) & 0xFF)
        let blue = Int(value & 0xFF)
        return ITermColor(
            red: red * componentScale16From8,
            green: green * componentScale16From8,
            blue: blue * componentScale16From8
        )
    }

    /// Renders iTerm2's 16-bit RGB components, plus an opacity, back to an 8-digit "RRGGBBAA" hex
    /// string, downscaling each RGB channel by dividing by 257 (the inverse of
    /// `itermColor(fromHexString:)`'s upscale) and rounding to the nearest 8-bit value rather than
    /// truncating, so a color built FROM a hex string round-trips back to that exact same string.
    /// `alpha` defaults to fully opaque so every pre-existing call site (the registered default in
    /// `AppDefaults`, chiefly) keeps emitting a valid hex string without having to think about
    /// opacity at all. `nonisolated static` for the same reason as its inverse above.
    nonisolated static func hexString(fromITermColor color: ITermColor, alpha: Double = 1.0) -> String {
        func component(_ value: Int) -> Int {
            let clamped = min(max(value, 0), 65535)
            return Int((Double(clamped) / Double(componentScale16From8)).rounded())
        }
        let alphaComponent = Int((min(max(alpha, 0), 1) * 255).rounded())
        return String(
            format: "%02X%02X%02X%02X",
            component(color.red), component(color.green), component(color.blue), alphaComponent
        )
    }

    /// The currently-tinted session, if any: its id, and the background color it had immediately
    /// before VoiceInk overwrote it, so unmarking can put back exactly what was there. Kept
    /// separate from `pinned` itself (rather than folded into `PinnedTarget.iTermSession`) so
    /// this purely cosmetic, best-effort side channel cannot affect the target's
    /// identity/equality or ripple into every existing call site that pattern-matches that case.
    private var activeITermMarking: (sessionID: String, previousBackgroundColor: ITermColor)?

    /// An iTerm2 color as the three 16-bit components its scripting interface uses. Always
    /// OPAQUE - iTerm2's `background color` property has no alpha channel, so every value of
    /// this type is something that can be written to it directly via
    /// `setBackgroundColorStatement`. This is exactly why opacity is not a fourth field here:
    /// see `ITermTintColor` and `blended(tint:alpha:over:)` for where opacity actually lives.
    struct ITermColor: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    /// A user-chosen tint plus the opacity to apply it at, together as parsed from the stored
    /// "RRGGBBAA" preference (see `itermColor(fromHexString:)`). Kept as its own small type
    /// rather than adding an `alpha` field to `ITermColor` itself, because `ITermColor` means "an
    /// opaque iTerm2 color, ready to write" everywhere else it's used (the captured original
    /// background, the fully-blended result) - folding alpha into it would let a caller pass a
    /// partially-transparent value straight to `setBackgroundColorStatement`, which has nowhere
    /// to put it (see the OPACITY discussion above `markITermSessionPinned`).
    struct ITermTintColor: Equatable {
        let color: ITermColor
        let alpha: Double
    }

    /// Alpha-blends `tint` over `background` (standard "source-over" compositing) and returns the
    /// resulting OPAQUE color, per channel: `background * (1 - alpha) + tint * alpha`, rounded to
    /// the nearest 16-bit component and clamped to iTerm2's 0...65535 range. This is the entire
    /// mechanism behind the pinned-tint "opacity" setting - see the OPACITY discussion above
    /// `markITermSessionPinned`, which is the only place this is called from. `alpha` is clamped
    /// to 0...1 defensively, since it can originate from a hand-edited or otherwise out-of-range
    /// stored preference. `nonisolated static` so this pure blend is unit-testable synchronously,
    /// same as the other color math in this file.
    nonisolated static func blended(tint: ITermColor, alpha: Double, over background: ITermColor) -> ITermColor {
        let clampedAlpha = min(max(alpha, 0), 1)

        func blend(_ tintComponent: Int, _ backgroundComponent: Int) -> Int {
            let mixed = Double(backgroundComponent) * (1 - clampedAlpha) + Double(tintComponent) * clampedAlpha
            return min(max(Int(mixed.rounded()), 0), 65535)
        }

        return ITermColor(
            red: blend(tint.red, background.red),
            green: blend(tint.green, background.green),
            blue: blend(tint.blue, background.blue)
        )
    }

    // MARK: - Menu bar icon foreground legibility

    // The menu bar's pinned icon (see `pinnedMenuBarIcon(from:tintHex:)` in VoiceInk.swift)
    // now fills its backdrop with the same tint the user picked for the pinned iTerm2 pane,
    // rather than a hard-coded green. The icon artwork itself is just a black-or-white mask,
    // and it used to be forced to white unconditionally - fine against the built-in dark
    // green, but a user-chosen tint could just as easily be pale, where a white icon would
    // vanish. So the mask color has to be DECIDED from the backdrop, every time.

    /// Which foreground reads legibly against a given backdrop - see
    /// `menuBarIconForeground(onBackdrop:)`.
    enum MenuBarIconForeground: Equatable {
        case light
        case dark
    }

    /// Picks the legible icon foreground for a given backdrop color, by relative brightness.
    /// Uses luma - `0.299R + 0.587G + 0.114B` on the plain (non-linearised) sRGB-gamma
    /// components, the ITU-R BT.601 weighting - rather than a flat `(R+G+B)/3` average: the
    /// eye is far more sensitive to green than to blue, so an unweighted average calls a
    /// saturated blue backdrop brighter than it reads and a saturated green backdrop darker
    /// than it reads - exactly backwards for the colors a tint picker produces most often.
    /// Working on plain gamma-encoded components rather than linearising first is a
    /// deliberate simplification: this only needs to sort a color into one of two buckets,
    /// not reproduce perceptually-linear brightness, and BT.601 luma is the well-known
    /// standard for exactly that.
    ///
    /// Threshold at luma 0.5 - the midpoint of the 0...1 range - with the tie (an exact
    /// 50% grey) landing on `.dark`: `>` rather than `>=` treats anywhere strictly below
    /// mid-brightness as needing the light foreground, and includes the midpoint itself
    /// among the "bright enough for a dark foreground" half. `nonisolated static` so this
    /// pure decision is unit-testable synchronously, same as the other color math in this
    /// file.
    nonisolated static func menuBarIconForeground(onBackdrop backdrop: ITermColor) -> MenuBarIconForeground {
        func normalized(_ component: Int) -> Double {
            Double(min(max(component, 0), 65535)) / 65535.0
        }

        let luma =
            0.299 * normalized(backdrop.red) + 0.587 * normalized(backdrop.green) + 0.114 * normalized(backdrop.blue)
        return luma > 0.5 ? .dark : .light
    }

    /// Parses the `r,g,b` string produced by `readITermSessionBackgroundColor`'s script. The
    /// components are formatted and re-joined explicitly by that script rather than relying on
    /// AppleScript's own list coercion, which renders `{0, 0, 0}` as the unparseable "000".
    /// `nonisolated static` so this pure parser is unit-testable synchronously, same as the
    /// other parsers in this file.
    nonisolated static func parseITermColor(_ raw: String?) -> ITermColor? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 3,
            let red = Int(parts[0].trimmingCharacters(in: .whitespaces)),
            let green = Int(parts[1].trimmingCharacters(in: .whitespaces)),
            let blue = Int(parts[2].trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }
        return ITermColor(red: red, green: green, blue: blue)
    }

    nonisolated static func setBackgroundColorStatement(_ color: ITermColor) -> String {
        "set background color to {\(color.red), \(color.green), \(color.blue)}"
    }

    // OPACITY. The user can pick not just a tint color but how strongly it applies, and that
    // needs to mean something specific: iTerm2's `background color` is an OPAQUE RGB triple -
    // its scripting interface has no alpha channel to set on it at all. iTerm2 sessions do have
    // a separate `transparency` property, but that is deliberately NOT what "opacity" means here
    // - it makes the whole pane see-through to the desktop behind it, which has nothing to do
    // with how strongly the TINT COLOR shows through the user's own terminal content.
    //
    // So opacity is implemented as alpha-blending the chosen tint over the pane's ORIGINAL
    // background color (standard source-over, see `blended(tint:alpha:over:)`) and writing the
    // resulting OPAQUE color - a lower opacity is a subtler wash over the existing scheme, not a
    // transparent window. This is only possible because `previousColor` below is captured BEFORE
    // any tinting happens; without it there would be nothing correct to blend against. A reader
    // who has not seen this reasoning would otherwise reasonably assume alpha was simply
    // forgotten when this method writes an opaque color despite the user having picked one with
    // opacity < 1 - it is not forgotten, it has already been folded in by the time of the write.

    /// Best-effort: tints `id`'s background, first capturing the color it already had so
    /// `clearActiveITermMarkingIfNeeded` can put it back exactly. Never awaited by its caller
    /// (see the `Task { ... }` in `toggle()`) - marking is a nicety, never a precondition for
    /// the pin itself, which has already succeeded by the time this runs. Every failure here is
    /// logged and swallowed, never surfaced as a pinning failure.
    private func markITermSessionPinned(id: String) async {
        guard UserDefaults.standard.bool(forKey: PinnedDestinationSettingsKeys.highlightPinnedITermSession)
        else {
            return
        }

        // No capture, no tint. Applying a color VoiceInk cannot undo would leave the user's
        // terminal permanently recolored with no way back short of reopening the pane. It also
        // doubles as the base to blend the tint's opacity against - see the OPACITY discussion
        // above.
        guard let previousColor = Self.parseITermColor(await readITermSessionBackgroundColor(id: id)) else {
            logger.notice("Skipping pinned iTerm2 session tint: could not read the session's current background color.")
            return
        }

        activeITermMarking = (sessionID: id, previousBackgroundColor: previousColor)

        let tint = pinnedTintColor()
        let blendedColor = Self.blended(tint: tint.color, alpha: tint.alpha, over: previousColor)
        let statement = Self.setBackgroundColorStatement(blendedColor)
        switch Self.classifyITermWriteOutcome(await writeToITermSession(id: id, statement: statement)) {
        case .ok:
            // Recorded only after the tint actually landed, so a failed write never leaves
            // a restore pending for a color that was never changed.
            persistActiveMarking(activeITermMarking)
            logger.notice("Tinted pinned iTerm2 session.")
        case .gone, .permissionDenied, .failed:
            logger.notice("Could not tint pinned iTerm2 session; continuing without it.")
            // Nothing was actually written, so there is nothing to restore later.
            activeITermMarking = nil
        }
    }

    /// Synchronously claims whatever marking is currently active (if any) and hands the actual
    /// restore off to a detached, unawaited task. Called from every path that stops a session
    /// being the pinned one: explicit unpin, re-pinning to a different target, and a pin
    /// self-clearing because the session died (`reportGone`) or delivery otherwise permanently
    /// failed (`reportDeliveryFailed`). Claiming the state synchronously - nil-ing it out before
    /// the restore even starts - is what guarantees a restore is attempted AT MOST once no
    /// matter how many of those paths run or how they interleave, and is also why this never
    /// awaits its own restore: unpinning must complete immediately regardless of how long the
    /// AppleScript round-trip to iTerm2 takes, since restoring a color is a nicety and must
    /// never add latency to the operation the user actually asked for.
    private func clearActiveITermMarkingIfNeeded() {
        guard let marking = activeITermMarking else { return }
        activeITermMarking = nil
        persistActiveMarking(nil)

        Task { [weak self] in
            await self?.restoreITermBackgroundColor(marking)
        }
    }

    private func restoreITermBackgroundColor(_ marking: (sessionID: String, previousBackgroundColor: ITermColor)) async
    {
        let statement = Self.setBackgroundColorStatement(marking.previousBackgroundColor)
        // Best-effort only: if the session already died (the exact case `reportGone` calls this
        // from), this write itself reports "gone" from the enumeration loop - that is expected,
        // not an error, and there is nothing further to do about it. Never throws, never
        // retried, never surfaced to the user - see the doc comment above.
        _ = await writeToITermSession(id: marking.sessionID, statement: statement)
    }

    /// Reads the background color of the session identified by `id` as an `r,g,b` string, using
    /// the same enumerate-and-compare pattern as every other iTerm2 lookup in this file (no
    /// top-level `session id "..."` specifier exists - see the note on `iTermSessionLiveness`).
    /// The components are formatted individually and joined with commas rather than returning
    /// the color list itself: AppleScript coerces `{0, 0, 0}` to the string "000", which cannot
    /// be split back into components. Returns nil if the session was not found or the read
    /// failed, which the caller treats as "do not tint at all".
    private func readITermSessionBackgroundColor(id: String) async -> String? {
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is "\(Self.escapedForAppleScript(id))" then
                                tell s
                                    set c to background color
                                end tell
                                return ((item 1 of c) as text) & "," & ((item 2 of c) as text) & "," & ((item 3 of c) as text)
                            end if
                        end repeat
                    end repeat
                end repeat
                return ""
            end tell
            """
        guard case .success(let value) = await runAppleScript(script) else { return nil }
        return value
    }

    // MARK: - AX delivery

    /// Outcome of delivering dictated text to an AX target and, if requested, trying to submit
    /// it - shared by both AX delivery mechanisms (`deliverToAXElement`'s value write and
    /// `deliverViaKeystrokes`'s synthesized input below), since both need to express the exact
    /// same three-way distinction. Kept distinct from a plain Bool because "the text landed but
    /// Return could not be sent" is neither a success (the user should know delivery is
    /// incomplete) nor a failure (the text is NOT lost and the pin is NOT dead) - see
    /// `finishDelivery`.
    enum AXDeliveryWriteOutcome: Equatable, Sendable {
        case delivered
        case deliveredWithoutSubmission
        case writeFailed
    }

    private func deliverToAXElement(element: AXUIElement, pid: pid_t, text: String, appendReturn: Bool)
        -> AXDeliveryWriteOutcome
    {
        var currentValueRef: CFTypeRef?
        let readStatus = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValueRef)
        guard readStatus == .success || readStatus == .noValue || readStatus == .attributeUnsupported else {
            return .writeFailed
        }

        let currentValue = (currentValueRef as? String) ?? ""
        // The transcript only - submission (if any) is a separate step below, never a
        // character appended to the value. A literal "\n" here would just insert a line
        // break into the field; it does not activate whatever "press Return" is supposed
        // to trigger (send a message, run a search, confirm a dialog, ...).
        let newValue = currentValue + text

        let setStatus = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        guard setStatus == .success else { return .writeFailed }

        guard appendReturn else { return .delivered }

        switch submitAXElement(element, pid: pid) {
        case .submittedViaConfirmAction, .submittedViaKeyEvent:
            return .delivered
        case .notSubmitted:
            return .deliveredWithoutSubmission
        }
    }

    /// Outcome of trying to submit (send Return) after a value write has already
    /// succeeded. Pure decision table, mirroring `decideToggle` / `decideAXDeliveryResolution`
    /// / `classifyAppleScriptError`: the actual AX action call and CGEvent post cannot be
    /// unit-tested, so this captures every branch of what to conclude from their results.
    enum AXSubmissionOutcome: Equatable, Sendable {
        case submittedViaConfirmAction
        case submittedViaKeyEvent
        case notSubmitted
    }

    // `nonisolated` so this pure lookup is unit-testable synchronously, same as the
    // other decision tables in this file.
    nonisolated static func decideAXSubmission(
        confirmActionSucceeded: Bool,
        keyEventPostSucceeded: Bool
    ) -> AXSubmissionOutcome {
        if confirmActionSucceeded { return .submittedViaConfirmAction }
        return keyEventPostSucceeded ? .submittedViaKeyEvent : .notSubmitted
    }

    /// Tries to submit without ever touching keyboard focus - no activation, no
    /// `kAXFrontmost`/`kAXMain`. Not stealing focus is the entire point of a pinned
    /// destination, so submission has to work around it rather than through it: first
    /// the element's own accessibility action (cleanest, no synthetic input at all),
    /// and only if that is not available or does not work, a synthetic key event
    /// targeted at the destination process specifically.
    private func submitAXElement(_ element: AXUIElement, pid: pid_t) -> AXSubmissionOutcome {
        let confirmActionSucceeded = performConfirmActionIfAdvertised(on: element)
        // Only pay for constructing and posting a synthetic key event when the
        // accessibility action route was not available or did not work.
        let keyEventPostSucceeded = confirmActionSucceeded ? false : postReturnKeyEvent(toPid: pid)
        return Self.decideAXSubmission(
            confirmActionSucceeded: confirmActionSucceeded,
            keyEventPostSucceeded: keyEventPostSucceeded
        )
    }

    /// Performs `kAXConfirmAction` only if the element itself advertises support for
    /// it via `AXUIElementCopyActionNames` - never guessed, never attempted blind.
    /// Many text controls (most plain text fields) do not advertise this, which is
    /// expected and not an error; the caller falls back to a synthetic key event.
    private func performConfirmActionIfAdvertised(on element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
            let actions = actionsRef as? [String],
            actions.contains(kAXConfirmAction)
        else {
            return false
        }

        return AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success
    }

    /// Posts a synthetic Return key-down/key-up pair straight to `pid` via
    /// `CGEvent.postToPid(_:)`, never through the HID/session event stream
    /// (`CGEvent.post(tap:)`). This distinction is the entire safety property this
    /// function exists for: `postToPid` delivers to the named process's own event queue
    /// regardless of which app is frontmost, whereas posting to
    /// `.cghidEventTap`/`.cgSessionEventTap` would go to whatever the user actually has
    /// focused - for a pinned-but-not-focused destination that is, by definition, the
    /// wrong app, and leaking a Return into it would be worse than the no-op this
    /// replaces. Posting an event this way also does
    /// not change which app is frontmost, so it cannot steal focus. Returns whether both
    /// events were successfully constructed and posted - `postToPid` itself
    /// returns no result and gives no confirmation that the target process actually
    /// processed the keystroke, so `true` here means "posted", not "definitely acted on".
    private func postReturnKeyEvent(toPid pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let source = CGEventSource(stateID: .privateState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else {
            return false
        }

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    // MARK: - Keystroke-injection delivery (axKeystrokeElement fallback)

    // How many UTF-16 code units to pack into a single synthetic key event's overridden
    // unicode string before starting a new event. `CGEventKeyboardSetUnicodeString`'s actual
    // internal buffer size is not documented by Apple and could not be verified without posting
    // events at a live target (this app must not launch/drive one to develop this feature), so
    // this stays conservative rather than assuming the string is passed through unbounded - a
    // dictated transcript can easily be a full paragraph, far longer than any commonly-cited
    // safe bound for a single event. Splitting into multiple small events is harmless even if
    // the true limit turns out to be much higher.
    private static let maxUnicodeCharactersPerKeyEvent = 20

    /// Splits `utf16` into chunks no longer than `maxChunkLength` UTF-16 code units, in order.
    /// `nonisolated static` so the chunking itself is unit-testable without any live CGEvent or
    /// process state - see `maxUnicodeCharactersPerKeyEvent` for why chunking exists at all.
    nonisolated static func unicodeStringChunks(_ utf16: [UInt16], maxChunkLength: Int) -> [[UInt16]] {
        guard !utf16.isEmpty else { return [] }
        guard maxChunkLength > 0 else { return [utf16] }
        return stride(from: 0, to: utf16.count, by: maxChunkLength).map {
            Array(utf16[$0..<Swift.min($0 + maxChunkLength, utf16.count)])
        }
    }

    /// Posts `text` to `pid` as one or more synthetic key events, each carrying a chunk of the
    /// string via `keyboardSetUnicodeString` rather than mapping characters to virtual key
    /// codes - a per-character keycode mapping cannot represent most non-ASCII text (accented
    /// letters, non-Latin scripts, emoji), and dictation must not silently mangle those. Always
    /// posts via `postToPid`, never `.cghidEventTap`/`.cgSessionEventTap` - see the doc comment
    /// on `postReturnKeyEvent` for why that distinction is the entire safety property this
    /// fallback depends on. Returns whether every chunk was successfully constructed and
    /// posted - as with `postReturnKeyEvent`, "posted" is not "confirmed acted on".
    private func postUnicodeString(_ text: String, toPid pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let chunks = Self.unicodeStringChunks(Array(text.utf16), maxChunkLength: Self.maxUnicodeCharactersPerKeyEvent)
        guard !chunks.isEmpty else { return true }

        let source = CGEventSource(stateID: .privateState)
        for chunk in chunks {
            // The virtual key code is a placeholder only - iTerm2's own docs and every public
            // example of this technique agree the receiving app reads the overridden unicode
            // string, not the key code, for events built this way. `kVK_ANSI_A` is used (rather
            // than 0) only so this never coincides with a code some app treats specially.
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)

            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        }

        return true
    }

    /// Reduces a keystroke-injection delivery attempt to the same `AXDeliveryWriteOutcome`
    /// shape `deliverToAXElement` produces, so `finishDelivery`'s `.axKeystrokeElement` case can
    /// handle both AX delivery mechanisms identically. Pure decision table, mirroring
    /// `decideAXSubmission`: the text posting and (optional) submit posting cannot themselves be
    /// unit-tested, but every branch of what to conclude from their results can be.
    /// `nonisolated` so this pure lookup is unit-testable synchronously.
    nonisolated static func decideKeystrokeDeliveryOutcome(
        textPostSucceeded: Bool,
        appendReturn: Bool,
        submitPostSucceeded: Bool
    ) -> AXDeliveryWriteOutcome {
        guard textPostSucceeded else { return .writeFailed }
        guard appendReturn else { return .delivered }
        return submitPostSucceeded ? .delivered : .deliveredWithoutSubmission
    }

    /// Delivers `text` to a keystroke-only pinned target (see `PinnedTarget.axKeystrokeElement`)
    /// by posting synthetic key events straight to `pid`, reusing `postReturnKeyEvent` for the
    /// optional submit step so both AX delivery mechanisms submit identically.
    private func deliverViaKeystrokes(pid: pid_t, text: String, appendReturn: Bool) -> AXDeliveryWriteOutcome {
        let textPosted = postUnicodeString(text, toPid: pid)
        let submitPosted = (textPosted && appendReturn) ? postReturnKeyEvent(toPid: pid) : false
        return Self.decideKeystrokeDeliveryOutcome(
            textPostSucceeded: textPosted, appendReturn: appendReturn, submitPostSucceeded: submitPosted)
    }

    // MARK: - AppleScript helper

    /// Outcome of executing an AppleScript. Distinguishes three situations that used
    /// to collapse into a single nil: the script ran and produced a value (which may
    /// itself carry an app-level "not found" result, e.g. `on error return ""`),
    /// Automation permission is missing so the script never ran at all, or execution
    /// failed for some other reason. `.permissionDenied` must never be treated as
    /// confirmation that a pinned destination is gone - see the call sites above.
    enum AppleScriptOutcome: Equatable, Sendable {
        case success(String?)
        case permissionDenied
        case failed
    }

    /// Coarse classification of an AppleScript execution failure, keyed off the
    /// numeric error code `NSAppleScript` reports. This is what lets `runAppleScript`
    /// tell "no Automation permission" apart from every other failure: Automation
    /// consent is keyed to the app's code signature, so an ad-hoc signed rebuild
    /// silently revokes it, and every pinned destination would otherwise start
    /// reporting itself as gone after every single build.
    enum AppleScriptFailureReason: Equatable, Sendable {
        case permissionDenied
        case targetNotRunning
        case other
    }

    // `nonisolated` so this pure lookup is unit-testable synchronously, mirroring
    // `decideToggle` / `decideAXDeliveryResolution` above.
    nonisolated static func classifyAppleScriptError(code: Int) -> AppleScriptFailureReason {
        switch code {
        case -1743, -1744:
            // errAEEventNotPermitted / errAEEventWouldRequireUserConsent: Automation
            // access has not been granted (or was granted for a previous build and
            // silently revoked by a rebuild - see the doc comment above).
            return .permissionDenied
        case -600:
            // procNotFound: the target application is not running at all. Kept as its
            // own case rather than folded into `.permissionDenied`, because the fix is
            // different ("launch the app" vs. "grant Automation access") - sending
            // someone whose app is simply closed to the Automation settings pane would
            // be its own small misdirection. Callers that only need "should this clear
            // the pin?" are free to treat it the same as `.other`.
            return .targetNotRunning
        default:
            return .other
        }
    }

    // `nonisolated static` so `appleScriptTextLiteral(for:)` below can call it as a
    // pure function, and both are unit-testable without any live AppleScript state.
    private nonisolated static func escapedForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Builds an AppleScript expression for `text` that survives embedded newlines and
    /// carriage returns. A raw line break cannot appear inside a single AppleScript
    /// string literal - it terminates the literal early and turns the generated script
    /// into invalid AppleScript, which then surfaces as an unrelated, misleading
    /// failure instead of delivering the (perfectly valid) multi-line dictated text.
    /// Splits on line boundaries and rejoins the pieces with AppleScript's own
    /// `linefeed` constant, so the script source stays on one line while the delivered
    /// text keeps every line break intact. `nonisolated static` so this pure builder is
    /// unit-testable synchronously, same as `escapedForAppleScript` above.
    nonisolated static func appleScriptTextLiteral(for text: String) -> String {
        guard !text.isEmpty else { return "\"\"" }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized
            .components(separatedBy: "\n")
            .map { "\"\(escapedForAppleScript($0))\"" }
            .joined(separator: " & linefeed & ")
    }

    /// Executes `source` and classifies the outcome. Runs off the main actor via an
    /// explicit `Task.detached`: iTerm2's AppleScript cost scales with how many
    /// windows/tabs/sessions are open (the enumeration used above visits all of them),
    /// so running this synchronously on the main thread could stall the whole app -
    /// including dropping an in-flight transcript - for however long that enumeration
    /// takes with many panes open. `nonisolated` so the function itself carries no
    /// actor affinity; the `Task.detached` is what actually guarantees the blocking
    /// AppleScript call happens off the main thread rather than merely being awaitable
    /// from it. No timeout is imposed: a slow-but-eventually-successful lookup must
    /// never be misreported as a dead destination, and moving the call off the main
    /// thread already removes the actual hazard (a frozen UI), so there is nothing left
    /// that a timeout would need to protect against here.
    private nonisolated func runAppleScript(_ source: String) async -> AppleScriptOutcome {
        let logger = self.logger
        return await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return .failed }

            var errorDict: NSDictionary?
            let result = script.executeAndReturnError(&errorDict)
            guard let errorDict else {
                return .success(result.stringValue)
            }

            logger.error("AppleScript error: \(errorDict, privacy: .public)")

            let code = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
            switch Self.classifyAppleScriptError(code: code) {
            case .permissionDenied:
                return .permissionDenied
            case .targetNotRunning, .other:
                return .failed
            }
        }.value
    }
}
