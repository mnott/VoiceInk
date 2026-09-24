import AppKit
import SwiftData
import SwiftUI

struct TranscriptionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var selectedTranscription: Transcription?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var selectionAnchor: Transcription?
    @State private var showDeleteConfirmation = false
    @State private var isShowingDeleted = false
    @State private var showPermanentDeleteConfirmation = false
    @State private var showEmptyConfirmation = false
    @State private var isViewCurrentlyVisible = false
    @State private var isAnalysisPanelPresented = false
    @State private var isLeftSidebarVisible = true
    @State private var isRightSidebarVisible = false
    @State private var leftSidebarWidth: CGFloat = 300
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    @State private var lastTimestamp: Date?
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

    private func openAnalysisPanel() {
        isRightSidebarVisible = false
        isAnalysisPanelPresented = true
    }

    private func closeAnalysisPanel() {
        isAnalysisPanelPresented = false
    }

    private func openInfoPanel() {
        isAnalysisPanelPresented = false
        isRightSidebarVisible = true
    }

    private func closeInfoPanel() {
        isRightSidebarVisible = false
    }

    var body: some View {
        HStack(spacing: 0) {
            if isLeftSidebarVisible {
                leftSidebarView
                    .frame(width: leftSidebarWidth)
                    .transition(.move(edge: .leading))

                Divider()
            }

            centerPaneView
                .frame(maxWidth: .infinity)
        }
        .background(historyBackground)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { withAnimation { isLeftSidebarVisible.toggle() } }) {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                Button(action: {
                    withAnimation {
                        isRightSidebarVisible ? closeInfoPanel() : openInfoPanel()
                    }
                }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
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
        .sidePanel(
            isPresented: .init(
                get: { isRightSidebarVisible },
                set: { newValue in
                    if !newValue { closeInfoPanel() }
                }
            )
        ) {
            infoSidePanelView
        }
        .sidePanel(
            isPresented: .init(
                get: { isAnalysisPanelPresented },
                set: { newValue in
                    if !newValue { closeAnalysisPanel() }
                }
            )
        ) {
            HistoryAnalysisPanelView(
                transcriptions: Array(selectedTranscriptions),
                onClose: closeAnalysisPanel
            )
            .id(selectedTranscriptions.count)
        }
        .background(WindowAccessor { window in hostingWindow = window })
        .onAppear {
            isViewCurrentlyVisible = true
            focusedField = .list
            installDeleteKeyMonitor()
            Task {
                await loadInitialContent()
            }
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
            selectedTranscription = nil
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

    private var historyBackground: some View {
        SidePanelBackground()
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarMaterialBackground: some View {
        VisualEffectView(
            material: .sidebar,
            blendingMode: .behindWindow
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var detailMaterialBackground: some View {
        SidePanelBackground()
            .ignoresSafeArea(.container, edges: .top)
    }

    private var leftSidebarView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField("Search transcriptions", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))
                    .focused($focusedField, equals: .search)

                Button(action: { withAnimation { isShowingDeleted.toggle() } }) {
                    Image(systemName: isShowingDeleted ? "trash.fill" : "trash")
                        .foregroundColor(isShowingDeleted ? AppTheme.Accent.primary : .secondary)
                }
                .buttonStyle(.plain)
                .help(isShowingDeleted ? "Back to History" : "Recently Deleted")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Surface.subtle)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .strokeBorder(AppTheme.Border.tint, lineWidth: 1)
                    }
            )
            .padding(12)

            Divider()

            ZStack(alignment: .bottom) {
                if displayedTranscriptions.isEmpty && !isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(isShowingDeleted ? "Recently Deleted is empty" : "No transcriptions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayedTranscriptions) { transcription in
                                TranscriptionListItem(
                                    transcription: transcription,
                                    isSelected: selectedTranscription == transcription,
                                    isChecked: selectedTranscriptions.contains(transcription),
                                    onSelect: {
                                        selectedTranscription = transcription
                                        selectionAnchor = transcription
                                    },
                                    onToggleCheck: { toggleSelection(transcription) },
                                    onSelectionClick: { modifier in handleSelectionClick(transcription, modifier: modifier) }
                                )
                            }

                            if hasMoreContent {
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
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                        .padding(8)
                        .padding(.bottom, 50)
                    }
                }

                if !displayedTranscriptions.isEmpty {
                    selectionToolbar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
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
        .background(sidebarMaterialBackground)
    }

    private var centerPaneView: some View {
        Group {
            if let transcription = selectedTranscription {
                TranscriptionDetailView(transcription: transcription, onInfoTap: openInfoPanel)
                    .id(transcription.id)
            } else {
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer()
                            .frame(minHeight: 40)

                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            Text("No Selection")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Select a transcription to view details")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }

                        HistoryShortcutTipView()
                            .padding(.horizontal, 24)

                        Spacer()
                            .frame(minHeight: 40)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 600)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(detailMaterialBackground)
    }

    private var infoSidePanelView: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Info", onClose: closeInfoPanel)

            if let transcription = selectedTranscription {
                TranscriptionInfoPanel(transcription: transcription)
                    .id(transcription.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Metadata")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }

            if !selectedTranscriptions.isEmpty {
                Divider()
                    .frame(height: 16)

                if isShowingDeleted {
                    Button(action: { restoreSelectedTranscriptions() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Restore")

                    Button(action: { showPermanentDeleteConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete Permanently")
                } else {
                    Button(action: {
                        openAnalysisPanel()
                    }) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Analyze")

                    Button(action: {
                        exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export")

                    Button(action: { showDeleteConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            } else if isShowingDeleted {
                Divider()
                    .frame(height: 16)

                Button("Empty", role: .destructive) { showEmptyConfirmation = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.Status.error)
            }

            Spacer()

            if !selectedTranscriptions.isEmpty {
                Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow
            )
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: -2)
        )
    }

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
        if selectedTranscription == transcription {
            selectedTranscription = nil
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

        Task {
            await saveAndReload()
        }
    }

    private func restoreSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performRestore(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task {
            await saveAndReload()
        }
    }

    private func permanentlyDeleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performPermanentDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task {
            await saveAndReload()
        }
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
