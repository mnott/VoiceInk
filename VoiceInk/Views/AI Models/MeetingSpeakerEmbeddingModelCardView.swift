import AppKit
import SwiftUI

/// Speaker-fingerprinting model for Meeting Capture's speaker library (see
/// `MeetingSpeakerEmbedder`/`Notes/speaker-library-spec.md`) - a separate download from the
/// turn-taking diarization model above, since it is FluidAudio's standard WeSpeaker embedding
/// model rather than Nemotron 3. Mirrors `MeetingDiarizationModelCardView`'s layout.
struct MeetingSpeakerEmbeddingModelCardView: View {
    @ObservedObject var manager: MeetingSpeakerEmbeddingModelManager

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                headerSection
                metadataSection
                descriptionSection
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionSection
        }
        .padding(16)
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Speaker Fingerprinting")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.labelColor))

            Text("Experimental")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 0.96, green: 0.79, blue: 0.63)))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 12) {
            Label("Meeting Capture", systemImage: "person.crop.circle.badge.checkmark")
            Label("~50 MB", systemImage: "internaldrive")
        }
        .font(.system(size: 11))
        .foregroundColor(Color(.secondaryLabelColor))
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(
            "Recognises remote speakers across meetings in the local speaker library (Audio settings -> Speakers), so a named voice keeps its name in later meetings. Not used for transcription."
        )
        .font(.system(size: 11))
        .foregroundColor(Color(.secondaryLabelColor))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    }

    private var progressSection: some View {
        Group {
            if let status = manager.downloadStatus {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.message)
                            .lineLimit(1)

                        if status.isIndeterminate {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.65)
                        }

                        Spacer()

                        Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                            .fontDesign(.monospaced)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))

                    ProgressView(value: status.fractionCompleted)
                        .progressViewStyle(LinearProgressViewStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .animation(.smooth, value: status.fractionCompleted)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            if manager.isDownloaded && !manager.isDownloading {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle")
            } else {
                Button(action: {
                    Task { await manager.download() }
                }) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(manager.isDownloading ? "Downloading..." : "Download"))
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppTheme.Accent.primary))
                }
                .buttonStyle(.plain)
                .disabled(manager.isDownloading)
            }

            if manager.isDownloaded && !manager.isDownloading {
                Menu {
                    Button(action: {
                        manager.delete()
                    }) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        manager.showInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }

                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            }
        }
    }
}
