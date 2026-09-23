import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    let action: ShortcutAction
    /// Which of the action's 0..n bindings (see `ShortcutStore`) this recorder edits. Actions
    /// with a single-recorder UI always use the default of 0 - their first (and only) binding.
    let index: Int
    let defaultShortcut: Shortcut?
    let onCancel: () -> Void
    let onShortcutChanged: () -> Void

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var recorderID = UUID()
    @State private var shortcut: Shortcut?

    init(
        action: ShortcutAction,
        index: Int = 0,
        defaultShortcut: Shortcut? = nil,
        onCancel: @escaping () -> Void = {},
        onShortcutChanged: @escaping () -> Void = {}
    ) {
        self.action = action
        self.index = index
        self.defaultShortcut = defaultShortcut
        self.onCancel = onCancel
        self.onShortcutChanged = onShortcutChanged
        _shortcut = State(initialValue: ShortcutStore.shortcut(for: action, at: index))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if recorder.isRecording {
                    recorder.cancel()
                } else {
                    NotificationCenter.default.post(
                        name: Self.shortcutRecordingDidStart,
                        object: recorderID
                    )
                    clearShortcutBeforeRecording()
                    recorder.start(
                        action: action,
                        index: index,
                        onCapture: { newShortcut in
                            shortcut = newShortcut
                            onShortcutChanged()
                        },
                        onCancel: onCancel
                    )
                }
            } label: {
                ShortcutVisualization(
                    shortcut: displayedShortcut,
                    isRecording: recorder.isRecording
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)

        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let changedAction = notification.object as? ShortcutAction, changedAction == action else { return }
            shortcut = ShortcutStore.shortcut(for: action, at: index)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.shortcutRecordingDidStart)) { notification in
            guard let activeRecorderID = notification.object as? UUID, activeRecorderID != recorderID else { return }
            recorder.cancel()
        }
        .onChange(of: action) { _, newAction in
            recorder.cancel()
            recorderID = UUID()
            shortcut = ShortcutStore.shortcut(for: newAction, at: index)
        }
        .onDisappear {
            recorder.cancel()
        }
    }

    private var accessibilityLabel: String {
        if recorder.isRecording {
            return recorder.previewShortcut?.displayString ?? String(localized: "Press shortcut")
        }

        return displayedShortcut?.displayString ?? String(localized: "Record shortcut")
    }

    private var displayedShortcut: Shortcut? {
        if recorder.isRecording {
            return recorder.previewShortcut
        }

        return shortcut ?? defaultShortcut
    }

    private func clearShortcutBeforeRecording() {
        ShortcutStore.removeShortcut(at: index, for: action)
        shortcut = nil
    }

    private static let shortcutRecordingDidStart = Notification.Name("ShortcutRecorderRecordingDidStart")
}

private struct ShortcutVisualization: View {
    let shortcut: Shortcut?
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let shortcut {
                ForEach(Array(shortcut.displayTokens.enumerated()), id: \.offset) { _, token in
                    ShortcutKeyCap(title: token, isRecording: isRecording)
                }
            } else {
                Text(isRecording ? LocalizedStringKey("Press shortcut") : LocalizedStringKey("Record"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isRecording ? .primary : .secondary)
            }
        }
        .padding(4)
        .frame(minWidth: shortcut == nil ? 104 : nil, minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? AppTheme.Accent.fill : AppTheme.Surface.control)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? AppTheme.Accent.border : AppTheme.Border.subtle, lineWidth: 1)
        }
    }
}

private struct ShortcutKeyCap: View {
    let title: String
    let isRecording: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            }
    }

    private var foregroundColor: Color {
        Color(NSColor.textBackgroundColor)
    }

    private var backgroundColor: Color {
        Color(NSColor.labelColor)
    }

    private var borderColor: Color {
        isRecording ? AppTheme.Accent.foreground : foregroundColor.opacity(0.28)
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var previewShortcut: Shortcut?

    private var localMonitor: Any?
    private var onCapture: ((Shortcut) -> Void)?
    private var onCancel: (() -> Void)?
    private var activeAction: ShortcutAction?
    private var activeIndex: Int = 0
    private var pendingModifierShortcut: Shortcut?
    private var peakModifierFlags: NSEvent.ModifierFlags = []

    deinit {
        removeRecordingMonitor()
    }

    func start(
        action: ShortcutAction,
        index: Int = 0,
        onCapture: @escaping (Shortcut) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        cancel()

        activeAction = action
        activeIndex = index
        self.onCapture = onCapture
        self.onCancel = onCancel
        isRecording = true
        previewShortcut = nil
        installRecordingMonitor()
    }

    func cancel() {
        let wasRecording = isRecording
        let cancelHandler = onCancel
        removeRecordingMonitor()
        resetRecordingState()
        if wasRecording {
            cancelHandler?()
        }
    }

    private func finish(with shortcut: Shortcut) {
        guard let activeAction else {
            cancel()
            return
        }

        if let validationError = ShortcutValidator.validationError(for: shortcut, action: activeAction) {
            cancel()
            showErrorNotification(validationError.notificationTitle(for: shortcut))
            return
        }

        let capture = onCapture
        let index = activeIndex
        removeRecordingMonitor()
        resetRecordingState()

        ShortcutStore.setShortcut(shortcut, for: activeAction, at: index)
        capture?(shortcut)
    }

    private func resetRecordingState() {
        isRecording = false
        previewShortcut = nil
        onCapture = nil
        onCancel = nil
        activeAction = nil
        activeIndex = 0
        pendingModifierShortcut = nil
        peakModifierFlags = []
    }

    private func showErrorNotification(_ title: String) {
        Task { @MainActor in
            NotificationManager.shared.showNotification(
                title: title,
                type: .error
            )
        }
    }

    private func installRecordingMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let shouldConsume = self.handleRecordingEvent(event)
            return shouldConsume ? nil : event
        }
    }

    private func removeRecordingMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard isRecording else {
            return false
        }

        switch event.type {
        case .keyDown:
            return handleKeyDown(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        case .flagsChanged:
            return handleFlagsChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        default:
            return false
        }
    }

    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode)

        if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancel()
            return true
        }

        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return true
        }

        let shortcut = Shortcut.key(keyCode: keyCode, modifierFlags: modifiers)
        previewShortcut = shortcut
        finish(with: shortcut)
        return true
    }

    private func handleFlagsChanged(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode)

        if modifiers.isEmpty,
            Shortcut.isFunctionKeyCode(keyCode),
            Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil).contains(.function)
        {
            return true
        }

        if !modifiers.isEmpty {
            peakModifierFlags.formUnion(modifiers)
            let singleModifierKeyCode = Shortcut.modifierKeyCodeForSingleModifierEvent(
                keyCode: keyCode,
                modifiers: peakModifierFlags
            )
            let shortcut = Shortcut.modifierOnly(
                keyCode: singleModifierKeyCode,
                modifierFlags: peakModifierFlags
            )

            pendingModifierShortcut = shortcut
            previewShortcut = shortcut
            return true
        }

        if let pendingModifierShortcut {
            finish(with: pendingModifierShortcut)
        }

        return true
    }
}
