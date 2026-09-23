import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(_ text: String) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
        let sessionID = UUID().uuidString

        guard
            ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: shouldRestoreClipboard ? sessionID : nil
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            return .commandNotPosted
        }

        await wait(prePasteDelay)

        let pasteResult = await postPasteCommand()
        if shouldRestoreClipboard {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return pasteResult
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand() async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return await pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard()
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID)
            else {
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    // Routed through `AppleScriptSerialExecutor`, same as every other NSAppleScript
    // execution in the app: NSAppleScript is not thread-safe, and this can otherwise
    // run concurrently with pinned-destination delivery's own AppleScript calls (a
    // different feature, but the same process-wide risk) - see the doc comment on
    // `AppleScriptSerialExecutor`.
    @MainActor
    private static func pasteUsingAppleScript() async -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        return await AppleScriptSerialExecutor.run {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
            }
            return error == nil
        }
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Insert-mode prefix (normal delivery)

    /// Sends "i" immediately followed by DEL to whatever is frontmost, posted via
    /// `.cghidEventTap` and gated on `AXIsProcessTrusted()` exactly like `performAutoSend` above -
    /// unlike `PinnedDestinationManager`'s pid-targeted equivalent, normal (unpinned) delivery has
    /// no captured target process to post to, only "whatever is frontmost right now", which is
    /// exactly what the event tap already delivers to.
    ///
    /// The pair is deliberately self-cancelling without needing to know the target's mode: from a
    /// modal TUI's normal mode (an interactive coding agent in a terminal, for example), "i"
    /// switches it into insert mode and is consumed as a command rather than typed, so the DEL
    /// that follows deletes nothing; from an already-active insert/typing mode, "i" is entered
    /// literally as text and the DEL immediately removes it. Either way the target is left exactly
    /// as if this pair had never been sent, and ready to receive the dictated text that follows -
    /// see the comment on `PinnedDestinationManager.insertModePrefixStatement` for the equivalent
    /// iTerm2-specific mechanism this mirrors.
    static func performInsertModePrefix() {
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)

        // "i" is posted as a Unicode string rather than mapped to a virtual key code, the same
        // technique `PinnedDestinationManager.postUnicodeString` uses: a virtual key code is a
        // physical key position, which is only "i" on a QWERTY layout, while a Unicode string
        // event types the character itself regardless of the active layout. `kVK_ANSI_A` is the
        // key code carried on the event only as a placeholder - the receiving app reads the
        // overridden unicode string, not the code - chosen (rather than 0) only so it never
        // coincides with a code some app treats specially.
        guard let iDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true),
            let iUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false)
        else {
            logger.error("Failed to create insert-mode prefix 'i' keyboard events")
            return
        }
        let iCharacter: [UniChar] = Array("i".utf16)
        iDown.keyboardSetUnicodeString(stringLength: iCharacter.count, unicodeString: iCharacter)
        iUp.keyboardSetUnicodeString(stringLength: iCharacter.count, unicodeString: iCharacter)

        // DEL (kVK_Delete) is a physical key position, not a character, so there is nothing
        // layout-dependent to translate - a virtual key code is exactly right here, unlike "i".
        guard let delDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
            let delUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
        else {
            logger.error("Failed to create insert-mode prefix DEL keyboard events")
            return
        }

        iDown.post(tap: .cghidEventTap)
        iUp.post(tap: .cghidEventTap)
        delDown.post(tap: .cghidEventTap)
        delUp.post(tap: .cghidEventTap)
    }
}
