import Foundation

/// Storage is a JSON array of `Shortcut` per action, so any action may have zero or more
/// bindings ("any of them triggers it" - see `ShortcutMonitor`). Data written before multiple
/// bindings existed is a single `Shortcut` object rather than an array; `rawShortcuts` reads that
/// old shape back as a one-element list so no stored binding is ever lost.
enum ShortcutStore {
    static let shortcutDidChange = Notification.Name("ShortcutStoreShortcutDidChange")

    static func rawShortcuts(for action: ShortcutAction) -> [Shortcut] {
        guard let data = shortcutData(for: action) else { return [] }

        if let list = try? JSONDecoder().decode([Shortcut].self, from: data) {
            return list
        }

        if let single = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return [single]
        }

        return []
    }

    static func rawShortcut(for action: ShortcutAction) -> Shortcut? {
        rawShortcuts(for: action).first
    }

    static func shortcuts(for action: ShortcutAction) -> [Shortcut] {
        guard action.isStored, !isShortcutCleared(for: action) else {
            return []
        }

        return rawShortcuts(for: action)
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts(for: action).first
    }

    static func shortcut(for action: ShortcutAction, at index: Int) -> Shortcut? {
        let bindings = shortcuts(for: action)
        return bindings.indices.contains(index) ? bindings[index] : nil
    }

    static func setShortcuts(_ shortcuts: [Shortcut], for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        guard shortcuts.allSatisfy({ ShortcutValidator.validationError(for: $0, action: action) == nil }) else {
            return
        }

        storeShortcuts(shortcuts, for: action)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        setShortcuts(shortcut.map { [$0] } ?? [], for: action)
    }

    /// Replaces (or, if `index` is one past the end, appends) a single binding. Used by the
    /// multi-binding recorder UI, where each row edits one slot of the action's binding list
    /// without disturbing the others.
    static func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction, at index: Int) {
        guard action.isStored, ShortcutValidator.validationError(for: shortcut, action: action) == nil else {
            return
        }

        var current = rawShortcuts(for: action)
        if current.indices.contains(index) {
            current[index] = shortcut
        } else {
            current.append(shortcut)
        }

        storeShortcuts(current, for: action)
    }

    static func removeShortcut(at index: Int, for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        var current = rawShortcuts(for: action)
        guard current.indices.contains(index) else {
            return
        }

        current.remove(at: index)
        storeShortcuts(current, for: action)
    }

    static func seedShortcut(
        _ shortcut: Shortcut,
        for action: ShortcutAction,
        replacingCleared: Bool = false
    ) {
        guard action.isStored,
            rawShortcut(for: action) == nil,
            replacingCleared || !isShortcutCleared(for: action)
        else {
            return
        }

        setShortcut(shortcut, for: action)
    }

    static func removeShortcutStorage(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    static func shortcuts(for actions: [ShortcutAction]) -> [ShortcutAction: [Shortcut]] {
        actions.reduce(into: [:]) { result, action in
            let bindings = shortcuts(for: action)
            if !bindings.isEmpty {
                result[action] = bindings
            }
        }
    }

    private static func storeShortcuts(_ shortcuts: [Shortcut], for action: ShortcutAction) {
        if shortcuts.isEmpty {
            UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
            UserDefaults.standard.set(true, forKey: clearedUserDefaultsKey(for: action))
        } else if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
            UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        } else {
            return
        }

        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    private static func shortcutData(for action: ShortcutAction) -> Data? {
        UserDefaults.standard.data(forKey: action.userDefaultsKey)
    }

    static func isShortcutCleared(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.bool(forKey: clearedUserDefaultsKey(for: action))
    }

    private static func clearedUserDefaultsKey(for action: ShortcutAction) -> String {
        "\(action.userDefaultsKey)_cleared"
    }
}
