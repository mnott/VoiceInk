import AppKit

/// Modifier key held during a click on a history row or its checkbox.
enum HistoryRowClickModifier {
    case command
    case shift

    /// Reads the live modifier flags during click handling (Shift/Cmd take
    /// priority over a plain click, which callers handle separately).
    static var current: HistoryRowClickModifier? {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return .shift }
        if flags.contains(.command) { return .command }
        return nil
    }
}

/// Pure range/toggle/select-all logic for multi-selecting history rows,
/// shared by TranscriptionHistoryView and InlineHistoryView.
enum HistorySelectionHelper {
    static func selection<Item: Hashable>(
        clicking item: Item,
        in visibleItems: [Item],
        current selection: Set<Item>,
        anchor: Item?,
        modifier: HistoryRowClickModifier
    ) -> (selection: Set<Item>, anchor: Item) {
        switch modifier {
        case .command:
            var newSelection = selection
            if newSelection.contains(item) {
                newSelection.remove(item)
            } else {
                newSelection.insert(item)
            }
            return (newSelection, item)

        case .shift:
            guard let anchor, let anchorIndex = visibleItems.firstIndex(of: anchor),
                let clickedIndex = visibleItems.firstIndex(of: item)
            else {
                return ([item], item)
            }
            let range = anchorIndex <= clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            var newSelection = selection
            for index in range {
                newSelection.insert(visibleItems[index])
            }
            return (newSelection, anchor)
        }
    }

    static func selectAll<Item: Hashable>(visibleItems: [Item]) -> Set<Item> {
        Set(visibleItems)
    }
}
