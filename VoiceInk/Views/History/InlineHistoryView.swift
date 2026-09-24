import AppKit
import SwiftData
import SwiftUI

struct InlineHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var expandedId: UUID?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var selectionAnchor: Transcription?
    @State private var showDeleteConfirmation = false
    @State private var isShowingDeleted = false
    @State private var showPermanentDeleteConfirmation = false
    @State private var showEmptyConfirmation = false
    @State private var isPanelPresented = false
    @State private var panelMode: InlineHistoryPanelMode = .info
    @State private var panelTranscriptionId: UUID?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    @State private var lastTimestamp: Date?
    @State private var isViewCurrentlyVisible = false
    @State private var hostingWindow: NSWindow?
    @State private var deleteKeyMonitor: Any?

    private enum HistoryFocusTarget: Hashable { case search, list }
    @FocusState private var focusedField: HistoryFocusTarget?

    private let exportService = VoiceInkCSVExportService()
    private let pageSize = 20

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private func cursorQueryDescriptor(after timestamp: Date? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        let showingDeleted = isShowingDeleted

        if let timestamp = timestamp {
            if !searchText.isEmpty {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.deletedAt != nil) == showingDeleted
                        && (transcription.text.localizedStandardContains(searchText)
                            || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false))
                        && transcription.timestamp < timestamp
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.deletedAt != nil) == showingDeleted && transcription.timestamp < timestamp
                }
            }
        } else if !searchText.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                (transcription.deletedAt != nil) == showingDeleted
                    && (transcription.text.localizedStandardContains(searchText)
                        || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false))
            }
        } else {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                (transcription.deletedAt != nil) == showingDeleted
            }
        }

        descriptor.fetchLimit = pageSize
        return descriptor
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var panelTranscription: Transcription? {
        guard let id = panelTranscriptionId else { return nil }
        return displayedTranscriptions.first { $0.id == id }
    }

    private func openPanel(mode: InlineHistoryPanelMode, transcriptionID: UUID? = nil) {
        panelMode = mode
        panelTranscriptionId = transcriptionID

        isPanelPresented = true
    }

    private func closePanel() {
        isPanelPresented = false
        panelMode = .info
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if displayedTranscriptions.isEmpty && !isLoading {
                emptyStateView
            } else {
                cardListView
                    .focusable()
                    .focused($focusedField, equals: .list)
                    .onKeyPress { keyPress in
                        if keyPress.key == "a" && keyPress.modifiers.contains(.command) {
                            selectAllVisibleTranscriptions()
                            return .handled
                        }
                        return .ignored
                    }
            }

            if !selectedTranscriptions.isEmpty || (isShowingDeleted && !displayedTranscriptions.isEmpty) {
                Divider()
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTranscriptions.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(
            isPresented: .init(
                get: { isPanelPresented },
                set: { newValue in
                    if !newValue { closePanel() }
                }
            )
        ) {
            panelContent
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HistoryDeleteMessage.softDelete(count: selectedTranscriptions.count))
        }
        .alert("Delete Permanently?", isPresented: $showPermanentDeleteConfirmation) {
            Button("Delete Permanently", role: .destructive) {
                permanentlyDeleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HistoryDeleteMessage.permanentDelete(count: selectedTranscriptions.count))
        }
        .alert("Empty Recently Deleted?", isPresented: $showEmptyConfirmation) {
            Button("Empty", role: .destructive) {
                emptyRecentlyDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. All items in Recently Deleted will be permanently deleted.")
        }
        .background(WindowAccessor { window in hostingWindow = window })
        .onAppear {
            isViewCurrentlyVisible = true
            focusedField = .list
            installDeleteKeyMonitor()
            Task { await loadInitialContent() }
        }
        .onDisappear {
            isViewCurrentlyVisible = false
            removeDeleteKeyMonitor()
        }
        .onChange(of: searchText) { _, _ in
            Task {
                await resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: isShowingDeleted) { _, _ in
            selectedTranscriptions.removeAll()
            Task {
                await resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                Task {
                    await resetPagination()
                    await loadInitialContent()
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedField, equals: .search)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(AppTheme.Surface.card)
            )
            .frame(maxWidth: .infinity)

            AppIconButton(
                systemName: isShowingDeleted ? "trash.fill" : "trash",
                help: isShowingDeleted ? "Back to History" : "Recently Deleted",
                size: 30,
                iconSize: 13,
                cornerRadius: AppTheme.Radius.pill
            ) {
                withAnimation { isShowingDeleted.toggle() }
            }

            AppIconButton(
                systemName: "gearshape",
                help: "History settings",
                size: 30,
                iconSize: 13,
                cornerRadius: AppTheme.Radius.pill
            ) {
                openPanel(mode: .historySettings)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            if !selectedTranscriptions.isEmpty {
                if isShowingDeleted {
                    Button(action: { restoreSelectedTranscriptions() }) {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button(action: { showPermanentDeleteConfirmation = true }) {
                        Label("Delete Permanently", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppTheme.Status.error.opacity(0.80))
                } else {
                    Button(action: {
                        openPanel(mode: .analysis)
                    }) {
                        Label("Analyze", systemImage: "chart.bar.xaxis")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button(action: {
                        exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                    }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppTheme.Status.error.opacity(0.80))
                }
            } else if isShowingDeleted {
                Button(role: .destructive, action: { showEmptyConfirmation = true }) {
                    Label("Empty", systemImage: "trash.slash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.Status.error.opacity(0.80))
            }

            Divider()
                .frame(height: 16)

            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            AppTheme.Surface.window
                .shadow(color: Color.black.opacity(0.1), radius: 3, y: -2)
        )
    }

    // MARK: - Empty State

    private var emptyStateTitle: String {
        if isShowingDeleted { return String(localized: "Recently Deleted is empty") }
        return searchText.isEmpty
            ? String(localized: "No transcriptions yet") : String(localized: "No results found")
    }

    private var emptyStateSubtitle: String {
        if isShowingDeleted { return String(localized: "Deleted items appear here for 30 days") }
        return searchText.isEmpty
            ? String(localized: "Your transcription history will appear here")
            : String(localized: "Try a different search term")
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(emptyStateTitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text(emptyStateSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card List

    private var cardListView: some View {
        Form {
            ForEach(displayedTranscriptions) { transcription in
                Section {
                    HistoryCardRow(
                        transcription: transcription,
                        isExpanded: expandedId == transcription.id,
                        isChecked: selectedTranscriptions.contains(transcription),
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedId = expandedId == transcription.id ? nil : transcription.id
                            }
                        },
                        onToggleCheck: { toggleSelection(transcription) },
                        onSelectionClick: { modifier in handleSelectionClick(transcription, modifier: modifier) },
                        onShowInfo: {
                            openPanel(mode: .info, transcriptionID: transcription.id)
                        }
                    )
                }
            }

            if hasMoreContent {
                Section {
                    Button(action: {
                        Task { await loadMoreContent() }
                    }) {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            }
                            Text(isLoading ? "Loading..." : "Load More")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var panelContent: some View {
        switch panelMode {
        case .info:
            infoPanelContent
        case .analysis:
            HistoryAnalysisPanelView(
                transcriptions: Array(selectedTranscriptions),
                onClose: {
                    closePanel()
                }
            )
            .id(selectedTranscriptions.count)
        case .historySettings:
            HistorySettingsPanel(onClose: closePanel)
        }
    }

    private var infoPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Info", onClose: closePanel)

            if let transcription = panelTranscription {
                TranscriptionInfoPanel(transcription: transcription)
                    .id(transcription.id)
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInitialContent() async {
        isLoading = true
        defer { isLoading = false }

        do {
            lastTimestamp = nil
            let items = try modelContext.fetch(cursorQueryDescriptor())
            displayedTranscriptions = items
            lastTimestamp = items.last?.timestamp
            hasMoreContent = items.count == pageSize
        } catch {
            print("Error loading transcriptions: \(error)")
        }
    }

    @MainActor
    private func loadMoreContent() async {
        guard !isLoading, hasMoreContent, let lastTimestamp = lastTimestamp else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let newItems = try modelContext.fetch(cursorQueryDescriptor(after: lastTimestamp))
            displayedTranscriptions.append(contentsOf: newItems)
            self.lastTimestamp = newItems.last?.timestamp
            hasMoreContent = newItems.count == pageSize
        } catch {
            print("Error loading more transcriptions: \(error)")
        }
    }

    @MainActor
    private func resetPagination() {
        displayedTranscriptions = []
        lastTimestamp = nil
        hasMoreContent = true
        isLoading = false
    }

    // MARK: - Selection & Deletion

    private func toggleSelection(_ transcription: Transcription) {
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
        selectionAnchor = transcription
    }

    private func handleSelectionClick(_ transcription: Transcription, modifier: HistoryRowClickModifier) {
        let result = HistorySelectionHelper.selection(
            clicking: transcription,
            in: displayedTranscriptions,
            current: selectedTranscriptions,
            anchor: selectionAnchor,
            modifier: modifier
        )
        selectedTranscriptions = result.selection
        selectionAnchor = result.anchor
    }

    private func selectAllVisibleTranscriptions() {
        guard !displayedTranscriptions.isEmpty else { return }
        selectedTranscriptions = HistorySelectionHelper.selectAll(visibleItems: displayedTranscriptions)
        selectionAnchor = displayedTranscriptions.last
    }

    private func installDeleteKeyMonitor() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window != nil, event.window === hostingWindow else { return event }
            let isEditingText = hostingWindow?.firstResponder is NSText
            guard
                HistoryDeleteKeyHandler.shouldRequestDelete(
                    keyCode: event.keyCode,
                    hasSelection: !selectedTranscriptions.isEmpty,
                    isEditingText: isEditingText
                )
            else { return event }

            if isShowingDeleted {
                showPermanentDeleteConfirmation = true
            } else {
                showDeleteConfirmation = true
            }
            return nil
        }
    }

    private func removeDeleteKeyMonitor() {
        if let deleteKeyMonitor {
            NSEvent.removeMonitor(deleteKeyMonitor)
            self.deleteKeyMonitor = nil
        }
    }

    private func clearSelectionState(for transcription: Transcription) {
        if expandedId == transcription.id {
            expandedId = nil
        }
        if panelTranscriptionId == transcription.id {
            panelTranscriptionId = nil
            closePanel()
        }
        if selectionAnchor == transcription {
            selectionAnchor = nil
        }
        selectedTranscriptions.remove(transcription)
    }

    private func performSoftDeletion(for transcription: Transcription) {
        clearSelectionState(for: transcription)
        TranscriptionTrashService.softDelete(transcription)
    }

    private func performRestore(for transcription: Transcription) {
        clearSelectionState(for: transcription)
        TranscriptionTrashService.restore(transcription)
    }

    private func performPermanentDeletion(for transcription: Transcription) {
        clearSelectionState(for: transcription)
        TranscriptionTrashService.permanentlyDelete(transcription, modelContext: modelContext)
    }

    private func saveAndReload() async {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
            await loadInitialContent()
        } catch {
            print("Error saving deletion: \(error.localizedDescription)")
            await loadInitialContent()
        }
    }

    private func deleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performSoftDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task { await saveAndReload() }
    }

    private func restoreSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performRestore(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task { await saveAndReload() }
    }

    private func permanentlyDeleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performPermanentDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task { await saveAndReload() }
    }

    private func emptyRecentlyDeleted() {
        Task {
            do {
                let descriptor = FetchDescriptor<Transcription>(predicate: TranscriptionTrashService.deletedPredicate())
                let items = try modelContext.fetch(descriptor)
                for transcription in items {
                    performPermanentDeletion(for: transcription)
                }
                await saveAndReload()
            } catch {
                print("Error emptying Recently Deleted: \(error.localizedDescription)")
            }
        }
    }

    private func selectAllTranscriptions() async {
        do {
            var allDescriptor = FetchDescriptor<Transcription>()
            let showingDeleted = isShowingDeleted

            if !searchText.isEmpty {
                allDescriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.deletedAt != nil) == showingDeleted
                        && (transcription.text.localizedStandardContains(searchText)
                            || (transcription.enhancedText?.localizedStandardContains(searchText) ?? false))
                }
            } else {
                allDescriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.deletedAt != nil) == showingDeleted
                }
            }

            allDescriptor.propertiesToFetch = [\.id]
            let allTranscriptions = try modelContext.fetch(allDescriptor)
            let visibleIds = Set(displayedTranscriptions.map { $0.id })

            await MainActor.run {
                selectedTranscriptions = Set(displayedTranscriptions)

                for transcription in allTranscriptions {
                    if !visibleIds.contains(transcription.id) {
                        selectedTranscriptions.insert(transcription)
                    }
                }
            }
        } catch {
            print("Error selecting all transcriptions: \(error)")
        }
    }
}

private enum InlineHistoryPanelMode {
    case info
    case analysis
    case historySettings
}

// MARK: - History Card Row

private struct HistoryCardRow: View {
    let transcription: Transcription
    let isExpanded: Bool
    let isChecked: Bool
    let onToggleExpand: () -> Void
    let onToggleCheck: () -> Void
    let onSelectionClick: (HistoryRowClickModifier) -> Void
    let onShowInfo: () -> Void

    @State private var selectedTab: TranscriptionTab = .original

    private var displayText: String {
        switch selectedTab {
        case .original:
            return transcription.text
        case .enhanced:
            return transcription.enhancedText ?? ""
        }
    }

    private var hasAudioFile: Bool {
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isChecked },
                        set: { _ in
                            if let modifier = HistoryRowClickModifier.current {
                                onSelectionClick(modifier)
                            } else {
                                onToggleCheck()
                            }
                        }
                    )
                )
                .toggleStyle(CircularCheckboxStyle())
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(transcription.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    if !isExpanded {
                        Text(transcription.enhancedText ?? transcription.text)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let modifier = HistoryRowClickModifier.current {
                    onSelectionClick(modifier)
                } else {
                    onToggleExpand()
                }
            }

            if isExpanded {
                expandedContent
                    .padding(.top, 10)
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tabs
            if transcription.enhancedText != nil {
                HStack(spacing: 4) {
                    ForEach(TranscriptionTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(LocalizedStringKey(tab.rawValue))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(selectedTab == tab ? AppTheme.Surface.controlActive : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            ScrollView {
                MarkdownContentView(
                    displayText,
                    fontSize: 14,
                    foregroundColor: AppTheme.Text.primary
                )
            }
            .frame(maxHeight: 350)
            .hoverCopyButton(textToCopy: displayText)

            if hasAudioFile, let urlString = transcription.audioFileURL,
                let url = URL(string: urlString)
            {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, onInfoTap: onShowInfo)
                    .padding(.vertical, 4)
            } else {
                HStack {
                    Spacer()
                    Button(action: onShowInfo) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("View details")
                }
            }
        }
    }
}
