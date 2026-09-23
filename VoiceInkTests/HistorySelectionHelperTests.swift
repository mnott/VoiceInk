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
