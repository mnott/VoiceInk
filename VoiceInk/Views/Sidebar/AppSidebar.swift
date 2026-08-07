import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType

    var body: some View {
        ZStack(alignment: .trailing) {
            sidebarBackground
            sidebarDivider
            sidebarContent
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarSection(ViewType.primaryItems)
                .padding(.top, 10)

            Spacer(minLength: 16)

            sidebarSection(ViewType.secondaryItems)
                .padding(.bottom, 14)

            if LocalBuildBadge.shouldShow {
                LocalBuildBadge()
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarBackground: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.control.opacity(0.55))
            .frame(width: 1)
            .ignoresSafeArea(.container, edges: .top)
    }

    private func sidebarSection(_ items: [ViewType]) -> some View {
        VStack(spacing: 3) {
            ForEach(items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType
                ) {
                    selectedView = viewType
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .transcribeAudio:
            return "Transcribe"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    static let primaryItems: [ViewType] = [
        .dashboard,
        .modes,
        .transcribeAudio,
        .history,
        .dictionary,
        .models,
        .audio,
    ]

    static let secondaryItems: [ViewType] = [
        .settings,
        .license,
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = primaryItems + secondaryItems
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .transcribeAudio: return "waveform.path"
        case .history: return "doc.text.fill"
        case .models: return "cpu"
        case .modes: return "sparkles.square.fill.on.square"
        case .audio: return "mic.fill"
        case .dictionary: return "text.book.closed.fill"
        case .settings: return "gearshape.fill"
        case .license: return "checkmark.seal.fill"
        }
    }

    var sidebarIconStyle: SidebarIconStyle {
        switch self {
        case .dashboard:
            return .init(background: AppTheme.Sidebar.dashboard)
        case .modes:
            return .init(background: AppTheme.Sidebar.modes)
        case .models:
            return .init(background: AppTheme.Sidebar.models)
        case .audio:
            return .init(background: AppTheme.Sidebar.fallback)
        case .dictionary:
            return .init(background: AppTheme.Sidebar.dictionary)
        case .history:
            return .init(background: AppTheme.Sidebar.audio)
        case .transcribeAudio:
            return .init(background: AppTheme.Sidebar.transcribeAudio)
        case .settings:
            return .init(background: AppTheme.Sidebar.fallback)
        case .license:
            return .init(background: AppTheme.Sidebar.license)
        }
    }
}

private struct SidebarIconStyle {
    let background: Color
    var foreground: Color = .white
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SidebarIconTile(
                    systemName: viewType.icon,
                    style: viewType.sidebarIconStyle
                )

                Text(viewType.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(rowBackgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(rowBorderColor, lineWidth: 1)
            }
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }

        return .clear
    }

    private var rowBorderColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.18) : .clear
    }

    private var selectedForegroundColor: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
}

/// Marks copies running in local mode so they are never mistaken for an official release.
///
/// Compiled unconditionally rather than behind `#if LOCAL_BUILD`, because local mode is no longer
/// purely a compile-time property: a build renamed to `VoiceInk-local.app` enters it at launch
/// (see `LicenseViewModel.isLocalModeByBundleName`). A compile-time-only badge could never reflect
/// that, leaving the one state most worth showing invisible.
private struct LocalBuildBadge: View {
    static var shouldShow: Bool {
        #if LOCAL_BUILD
            return true
        #else
            return LicenseViewModel.isLocalModeByBundleName
        #endif
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        Text("LOCAL \(version)")
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.85))
            )
    }
}

private struct SidebarIconTile: View {
    let systemName: String
    let style: SidebarIconStyle

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(style.background)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 11)
                        .blendMode(.screen)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 1.2, y: 1)

            Image(systemName: systemName)
                .font(.system(size: 14.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(style.foreground)
                .shadow(color: Color.black.opacity(0.16), radius: 0.5, y: 0.5)
        }
        .frame(width: 24, height: 24)
    }
}
