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

                TextField(
                    "Name",
                    text: Binding(
                        get: { voice.name ?? "" },
                        set: { newValue in
                            SpeakerLibraryService.rename(id: voice.id, to: newValue, library: library, modelContext: modelContext)
                        })
                )
                .textFieldStyle(.roundedBorder)

                Text(voice.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

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
