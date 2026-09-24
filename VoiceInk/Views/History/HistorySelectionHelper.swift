import AppKit
import Carbon.HIToolbox

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

/// Decides whether a Delete / Forward Delete key press should open the
/// History page's delete confirmation. Driven by a window-level `NSEvent`
/// monitor rather than SwiftUI's `onKeyPress`: clicking a row's selection
/// checkbox moves AppKit focus to that button, so `onKeyPress` on the list
/// never sees the key again even though a selection is still active.
enum HistoryDeleteKeyHandler {
    static func shouldRequestDelete(keyCode: UInt16, hasSelection: Bool, isEditingText: Bool) -> Bool {
        guard hasSelection, !isEditingText else { return false }
        return keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)
    }
}

/// Singular/plural message text shared by the History and Recently Deleted
/// delete confirmations, so "1 item" isn't reported as "1 items".
enum HistoryDeleteMessage {
    static func softDelete(count: Int) -> String {
        count == 1
            ? String(localized: "1 item will be moved to Recently Deleted.")
            : String(localized: "\(count) items will be moved to Recently Deleted.")
    }

    static func permanentDelete(count: Int) -> String {
        count == 1
            ? String(localized: "This action cannot be undone. Permanently delete 1 item?")
            : String(localized: "This action cannot be undone. Permanently delete \(count) items?")
    }
}
