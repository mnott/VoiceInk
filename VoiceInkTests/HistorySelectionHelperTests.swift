import Carbon.HIToolbox
import Testing
@testable import VoiceInk

// MARK: - History: multi-select range/toggle/select-all logic

struct HistorySelectionHelperTests {
    private let visible = [1, 2, 3, 4, 5]

    @Test func shiftClickSelectsRangeFromAnchor() {
        let result = HistorySelectionHelper.selection(
            clicking: 4,
            in: visible,
            current: [2],
            anchor: 2,
            modifier: .shift
        )
        #expect(result.selection == [2, 3, 4])
        #expect(result.anchor == 2)
    }

    @Test func shiftClickBackwardsSelectsRangeFromAnchor() {
        let result = HistorySelectionHelper.selection(
            clicking: 1,
            in: visible,
            current: [4],
            anchor: 4,
            modifier: .shift
        )
        #expect(result.selection == [1, 2, 3, 4])
        #expect(result.anchor == 4)
    }

    @Test func shiftClickWithoutAnchorSelectsOnlyClickedItem() {
        let result = HistorySelectionHelper.selection(
            clicking: 3,
            in: visible,
            current: [],
            anchor: nil,
            modifier: .shift
        )
        #expect(result.selection == [3])
        #expect(result.anchor == 3)
    }

    @Test func commandClickTogglesSingleItemAndUpdatesAnchor() {
        let selected = HistorySelectionHelper.selection(
            clicking: 3,
            in: visible,
            current: [1],
            anchor: 1,
            modifier: .command
        )
        #expect(selected.selection == [1, 3])
        #expect(selected.anchor == 3)

        let deselected = HistorySelectionHelper.selection(
            clicking: 1,
            in: visible,
            current: selected.selection,
            anchor: selected.anchor,
            modifier: .command
        )
        #expect(deselected.selection == [3])
        #expect(deselected.anchor == 1)
    }

    @Test func selectAllOverFilteredListOnlyIncludesVisibleItems() {
        let filtered = [2, 4]
        #expect(HistorySelectionHelper.selectAll(visibleItems: filtered) == [2, 4])
    }
}

// MARK: - History: Delete key decision logic

struct HistoryDeleteKeyHandlerTests {
    @Test func deleteKeyWithSelectionAndNoTextEditingRequestsDelete() {
        #expect(
            HistoryDeleteKeyHandler.shouldRequestDelete(
                keyCode: UInt16(kVK_Delete), hasSelection: true, isEditingText: false))
    }

    @Test func forwardDeleteKeyWithSelectionAndNoTextEditingRequestsDelete() {
        #expect(
            HistoryDeleteKeyHandler.shouldRequestDelete(
                keyCode: UInt16(kVK_ForwardDelete), hasSelection: true, isEditingText: false))
    }

    @Test func deleteKeyWithoutSelectionDoesNotRequestDelete() {
        #expect(
            !HistoryDeleteKeyHandler.shouldRequestDelete(
                keyCode: UInt16(kVK_Delete), hasSelection: false, isEditingText: false))
    }

    @Test func deleteKeyWhileEditingTextDoesNotRequestDelete() {
        #expect(
            !HistoryDeleteKeyHandler.shouldRequestDelete(
                keyCode: UInt16(kVK_Delete), hasSelection: true, isEditingText: true))
    }

    @Test func unrelatedKeyDoesNotRequestDelete() {
        #expect(
            !HistoryDeleteKeyHandler.shouldRequestDelete(
                keyCode: UInt16(kVK_ANSI_A), hasSelection: true, isEditingText: false))
    }
}

// MARK: - History: pluralised delete confirmation messages

struct HistoryDeleteMessageTests {
    @Test func softDeleteMessageUsesSingularForOne() {
        #expect(HistoryDeleteMessage.softDelete(count: 1) == "1 item will be moved to Recently Deleted.")
    }

    @Test func softDeleteMessageUsesPluralForMultiple() {
        #expect(HistoryDeleteMessage.softDelete(count: 3) == "3 items will be moved to Recently Deleted.")
    }

    @Test func permanentDeleteMessageUsesSingularForOne() {
        #expect(
            HistoryDeleteMessage.permanentDelete(count: 1)
                == "This action cannot be undone. Permanently delete 1 item?")
    }

    @Test func permanentDeleteMessageUsesPluralForMultiple() {
        #expect(
            HistoryDeleteMessage.permanentDelete(count: 5)
                == "This action cannot be undone. Permanently delete 5 items?")
    }
}
