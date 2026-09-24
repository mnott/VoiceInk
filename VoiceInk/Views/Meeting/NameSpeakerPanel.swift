import AppKit
import SwiftUI

// MARK: - Manager

/// Floating panel for the "Name Speaker" hotkey, following `DictionaryQuickAddManager`'s pattern:
/// a small non-activating panel with one text field, dismissed on Escape/losing key.
@MainActor
final class NameSpeakerManager {
    static let shared = NameSpeakerManager()
    private init() {}

    private var panel: NameSpeakerPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(engine: VoiceInkEngine) {
        isVisible ? hide() : show(engine: engine)
    }

    func show(engine: VoiceInkEngine) {
        guard !isVisible, engine.isMeetingCaptureActive, engine.liveSpeakerTracker.state.mostRecentRemoteSlot != nil
        else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        let size = NSSize(width: 420, height: 100)
        let newPanel = NameSpeakerPanel(manager: self, size: size)

        let view = NameSpeakerView(
            library: SpeakerLibraryStore.shared,
            onSubmit: { name in
                Task { await engine.nameCurrentMeetingSpeaker(name) }
            },
            onDismiss: { [weak self] in self?.hide() }
        )

        let controller = NSHostingController(rootView: AnyView(view))
        newPanel.contentView = controller.view
        hostingController = controller
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }
}

// MARK: - Panel

class NameSpeakerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private weak var manager: NameSpeakerManager?

    init(manager: NameSpeakerManager, size: NSSize) {
        self.manager = manager
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2 + 60)
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            manager?.hide()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            self?.manager?.hide()
        }
    }
}

// MARK: - View

struct NameSpeakerView: View {
    @ObservedObject var library: SpeakerLibraryStore
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var nameInput = ""
    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        guard !nameInput.isEmpty else { return [] }
        return library.voices.compactMap(\.name)
            .filter { $0.localizedCaseInsensitiveContains(nameInput) }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("", text: $nameInput, prompt: Text("Name this speaker").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit(submit)
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) {
                                nameInput = name
                                submit()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Border.tint, lineWidth: 0.5)
        )
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private func submit() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        onDismiss()
    }
}
