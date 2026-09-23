import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
    }

    /// Each action maps to all of its bound shortcuts (0..n) - see `ShortcutStore`. Any binding
    /// transitioning to key-down/key-up dispatches for the action; a second binding's key-down
    /// while the action is already considered "down" is naturally absorbed by callers' own
    /// re-entrancy guards (e.g. `RecordingShortcutModeHandler.handleKeyDown`'s `isShortcutPressed`
    /// check), so no extra dedup lives here.
    private var shortcuts: [ShortcutAction: [ShortcutState]] = [:]
    private var interruptibleActions: Set<ShortcutAction> = []
    private var onKeyDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onKeyUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var eventTapThread: Thread?
    private var eventTapRunLoop: CFRunLoop?
    /// Guards all mutable shortcut state. The tap callback runs on `eventTapThread`
    /// while `start`/`stop` run on the caller's (main) thread, so every access to
    /// `shortcuts`/`interruptibleActions`/the handler closures goes through this lock.
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: [Shortcut]],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil
    ) -> Bool {
        stop()

        stateLock.lock()
        for (action, actionShortcuts) in shortcuts where !actionShortcuts.isEmpty {
            self.shortcuts[action] = actionShortcuts.map { ShortcutState(shortcut: $0) }
        }

        let isEmpty = self.shortcuts.isEmpty
        self.interruptibleActions = interruptibleActions
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onShortcutInterrupted = onShortcutInterrupted
        stateLock.unlock()

        guard !isEmpty else {
            return true
        }

        return installEventTap()
    }

    func stop() {
        stateLock.lock()
        let runLoop = eventTapRunLoop
        let source = eventTapRunLoopSource
        let tap = eventTap
        eventTapRunLoop = nil
        eventTapRunLoopSource = nil
        eventTap = nil
        eventTapThread = nil
        shortcuts = [:]
        interruptibleActions = []
        onKeyDown = nil
        onKeyUp = nil
        onShortcutInterrupted = nil
        stateLock.unlock()

        if let runLoop {
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFRunLoopStop(runLoop)
        }

        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                monitor.stateLock.lock()
                let eventTap = monitor.eventTap
                monitor.stateLock.unlock()
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        stateLock.lock()
        self.eventTap = eventTap
        eventTapRunLoopSource = source
        stateLock.unlock()

        // The tap's run-loop source lives on a DEDICATED thread, never the main run
        // loop. This tap is an active tap on the session event stream: every keystroke
        // on the machine waits for this callback, so servicing it from the main run
        // loop couples system-wide keyboard input to this app's main thread - any
        // main-thread stall (model loading, a hung dialog, a debugger pause) then
        // freezes typing everywhere, and because the timeout-recovery branch above
        // also ran on the blocked loop, it could never re-enable the tap, making the
        // freeze permanent until this process was killed. This has locked up the whole
        // machine in live use - do not move the source back to the main run loop.
        let readySemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                readySemaphore.signal()
                return
            }
            self.stateLock.lock()
            self.eventTapRunLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            readySemaphore.signal()
            CFRunLoopRun()
        }
        thread.name = "com.prakashjoshipax.voiceink.shortcut-event-tap"
        thread.qualityOfService = .userInteractive
        stateLock.lock()
        eventTapThread = thread
        stateLock.unlock()
        thread.start()
        readySemaphore.wait()
        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let eventKind = EventKind(type) else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        return handleEvent(
            kind: eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        stateLock.lock()
        defer { stateLock.unlock() }

        let eventTime = ProcessInfo.processInfo.systemUptime
        let pressedActions = shortcuts.compactMap { action, states in
            states.contains { $0.isDown } ? action : nil
        }

        guard !pressedActions.isEmpty else {
            return
        }

        for action in pressedActions {
            shortcuts[action] = shortcuts[action]?.map { state in
                var state = state
                if state.isDown {
                    state.isDown = false
                    state.pressedAt = nil
                    state.isInterrupted = false
                }
                return state
            }
            dispatchKeyUp(for: action, eventTime: eventTime)
        }
    }

    private func handleEvent(
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        // Runs on the dedicated tap thread while start()/stop() mutate the same state
        // from the main thread. The handler closures fired by dispatch* still hop to
        // the main queue, so holding the lock here never waits on user-level work.
        stateLock.lock()
        defer { stateLock.unlock() }

        var shouldSuppress = false

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: keyCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var states = shortcuts[action] else {
                continue
            }

            for index in states.indices {
                let state = states[index]

                // Modifier-only shortcuts (e.g. a lone Right ⌘) never suppress the underlying
                // flags-changed event - only key-type shortcuts do, since suppressing a
                // modifier key's event would also swallow it for every other app.
                let transition: ShortcutTransition
                let suppressesOnTrigger: Bool
                if state.shortcut.isModifierOnly {
                    transition = Self.transitionForModifierOnlyShortcut(
                        state.shortcut, isDown: state.isDown, kind: kind, keyCode: keyCode,
                        modifierFlags: modifierFlags)
                    suppressesOnTrigger = false
                } else {
                    transition = Self.transitionForKeyShortcut(
                        state.shortcut, isDown: state.isDown, kind: kind, keyCode: keyCode,
                        modifierFlags: modifierFlags)
                    suppressesOnTrigger = true
                }

                switch transition {
                case .none:
                    break
                case .suppress:
                    shouldSuppress = true
                case .keyDown:
                    states[index].isDown = true
                    states[index].pressedAt = eventTime
                    states[index].isInterrupted = false
                    if suppressesOnTrigger { shouldSuppress = true }
                    dispatchKeyDown(for: action, eventTime: eventTime)
                case .keyUp:
                    states[index].isDown = false
                    states[index].pressedAt = nil
                    states[index].isInterrupted = false
                    if suppressesOnTrigger { shouldSuppress = true }
                    dispatchKeyUp(for: action, eventTime: eventTime)
                }
            }

            shortcuts[action] = states
        }

        return shouldSuppress
    }

    enum ShortcutTransition: Equatable {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    /// Pure: given one binding's current down/up state and an incoming event, what should happen
    /// to it. Kept static (no `self`) so the "does any binding of an action trigger" resolution
    /// is directly unit-testable without standing up the event tap.
    static func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        }
    }

    static func transitionForModifierOnlyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        guard kind == .flagsChanged else {
            return .none
        }

        if isDown {
            return shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags)
                ? .keyUp : .none
        }

        return shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) ? .keyDown : .none
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in interruptibleActions {
            guard var states = shortcuts[action] else {
                continue
            }

            for index in states.indices {
                let state = states[index]
                guard state.isDown,
                    !state.isInterrupted,
                    let pressedAt = state.pressedAt,
                    eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                    state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
                else {
                    continue
                }

                states[index].isInterrupted = true
                dispatchShortcutInterrupted(for: action, eventTime: eventTime)
            }

            shortcuts[action] = states
        }
    }

    private func dispatchKeyDown(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onKeyDown] in
            onKeyDown?(action, eventTime)
        }
    }

    private func dispatchKeyUp(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onKeyUp] in
            onKeyUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }
}
