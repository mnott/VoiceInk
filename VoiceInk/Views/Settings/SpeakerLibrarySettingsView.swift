import AVFoundation
import SwiftData
import SwiftUI

/// Audio settings -> Speakers: every voice the local speaker library has ever heard, with a
/// rename field, a sample player, a merge-into-another-voice picker, and delete. See
/// `Notes/speaker-library-spec.md`.
struct SpeakerLibrarySettingsView: View {
    @ObservedObject private var library = SpeakerLibraryStore.shared
    @Environment(\.modelContext) private var modelContext
    @State private var player: AVAudioPlayer?
    @State private var mergeSourceID: String?
    @State private var showDeleteAllConfirmation = false

    private var sortedVoices: [SpeakerVoice] {
        library.voices.sorted { $0.lastHeard > $1.lastHeard }
    }

    var body: some View {
        Group {
            if sortedVoices.isEmpty {
                Text("No voices identified yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedVoices) { voice in
                    row(for: voice)
                }

                Button("Delete All", role: .destructive) { showDeleteAllConfirmation = true }
            }
        }
        .confirmationDialog(
            "Delete every remembered voice?", isPresented: $showDeleteAllConfirmation, titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                SpeakerLibraryService.deleteAll(library: library, modelContext: modelContext)
            }
        }
    }

    private func row(for voice: SpeakerVoice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: { play(voice) }) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .disabled(voice.sampleClipFileNames.isEmpty)

                NameField(voice: voice, library: library, modelContext: modelContext)

                Text(voice.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                Toggle(
                    "This is me",
                    isOn: Binding(
                        get: { voice.isMe },
                        set: { library.setIsMe(id: voice.id, isMe: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(
                    "Flag this voice as you, so Meeting Capture's in-person mode (diarizing the microphone instead of a call's system audio) can label your own turns \"Me\" instead of a speaker id. Only one voice can be flagged at a time."
                )

                Menu("Merge Into…") {
                    ForEach(sortedVoices.filter { $0.id != voice.id }) { target in
                        Button(target.name ?? target.id) {
                            SpeakerLibraryService.merge(
                                sourceID: voice.id, intoTargetID: target.id, library: library, modelContext: modelContext)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(sortedVoices.count < 2)

                Button(role: .destructive) {
                    SpeakerLibraryService.delete(id: voice.id, library: library, modelContext: modelContext)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            Text(
                String(
                    format: String(localized: "Last heard %@ · %d meeting(s)"),
                    voice.lastHeard.formatted(date: .abbreviated, time: .shortened), voice.meetingsCount)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func play(_ voice: SpeakerVoice) {
        guard let fileName = voice.sampleClipFileNames.first else { return }
        player = try? AVAudioPlayer(contentsOf: library.clipURL(for: fileName))
        player?.play()
    }
}

/// Rename field for one voice. Deliberately does NOT persist on every keystroke: it edits a local
/// draft and commits (via `SpeakerLibraryService.rename`, which also re-renders every meeting that
/// references this voice - not cheap enough to run per character) only on Return or on losing
/// keyboard focus. Editing on every keystroke previously left the field armed to silently overwrite
/// a voice's name with whatever stray text (e.g. dictation typed at the cursor elsewhere) reached it
/// next, for as long as Return - which does not resign focus - left it the first responder.
private struct NameField: View {
    let voice: SpeakerVoice
    let library: SpeakerLibraryStore
    let modelContext: ModelContext

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(voice: SpeakerVoice, library: SpeakerLibraryStore, modelContext: ModelContext) {
        self.voice = voice
        self.library = library
        self.modelContext = modelContext
        _draft = State(initialValue: voice.name ?? "")
    }

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                guard !focused else { return }
                commit()
            }
            .onChange(of: voice.name) { _, newValue in
                // A rename that landed some other way (merge, a live match during Meeting
                // Capture) while this field isn't the one being edited - reflect it here too,
                // but never clobber text the user is actively typing.
                guard !isFocused else { return }
                draft = newValue ?? ""
            }
    }

    private func commit() {
        guard let value = SpeakerLibraryService.valueToPersist(draft: draft, currentName: voice.name) else { return }
        SpeakerLibraryService.rename(id: voice.id, to: value, library: library, modelContext: modelContext)
    }
}
