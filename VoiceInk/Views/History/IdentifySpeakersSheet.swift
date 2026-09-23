import AVFoundation
import SwiftData
import SwiftUI

/// Shown after "Identify Speakers" (see `AudioPlayerView`) finds voices in a meeting record that
/// the library couldn't already put a name to. One row per still-unnamed `spk-` id: a play button
/// for its clearest sample clip, a name field with autocomplete against every named voice in the
/// library (picking a suggestion merges into that voice rather than creating a same-named
/// duplicate - see `Notes/speaker-library-spec.md`), and Skip (leave it unnamed for now).
struct IdentifySpeakersSheet: View {
    let unnamedIDs: [String]
    @ObservedObject var library: SpeakerLibraryStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var names: [String: String] = [:]
    @State private var player: AVAudioPlayer?

    private var namedSuggestions: [String] {
        library.voices.compactMap(\.name).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Identify Speakers")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(unnamedIDs, id: \.self) { id in
                        row(for: id)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Done") {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(for id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: { play(id: id) }) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .disabled(library.voice(for: id)?.sampleClipFileNames.isEmpty ?? true)

                Text(id).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)

                TextField(
                    "Name", text: Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
                )
                .textFieldStyle(.roundedBorder)
            }

            if !namedSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(namedSuggestions, id: \.self) { name in
                            Button(name) { names[id] = name }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func play(id: String) {
        guard let fileName = library.voice(for: id)?.sampleClipFileNames.first else { return }
        player = try? AVAudioPlayer(contentsOf: library.clipURL(for: fileName))
        player?.play()
    }

    private func commit() {
        for id in unnamedIDs {
            let trimmed = (names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let existing = library.voices.first(where: { $0.id != id && $0.name?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                SpeakerLibraryService.merge(sourceID: id, intoTargetID: existing.id, library: library, modelContext: modelContext)
            } else {
                SpeakerLibraryService.rename(id: id, to: trimmed, library: library, modelContext: modelContext)
            }
        }
    }
}
