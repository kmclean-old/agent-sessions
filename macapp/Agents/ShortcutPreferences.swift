import AppKit
import Combine

/// One live map for menus, event routing and help. Only differences from the
/// factory map are persisted; an explicit nil means the user cleared a binding.
@MainActor
final class ShortcutPreferences: ObservableObject {
    static let defaultsKey = "keyboardShortcutOverrides.v1"

    private struct Override: Codable {
        var shortcut: Shortcut?
    }

    @Published private(set) var bindings: [AppAction: Shortcut]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var bindings = Keymap.standard
        if let data = defaults.data(forKey: Self.defaultsKey),
           let overrides = try? JSONDecoder().decode([String: Override].self, from: data) {
            for action in AppAction.allCases {
                if let override = overrides[action.preferenceID] {
                    bindings[action] = override.shortcut
                }
            }
        }
        // Corrupt or incompatible preferences must never install an ambiguous
        // map. Unknown action IDs are ignored to allow version transitions.
        self.bindings = Self.validationErrors(in: bindings).isEmpty ? bindings : Keymap.standard
    }

    @discardableResult
    func save(_ bindings: [AppAction: Shortcut]) -> Bool {
        guard Self.validationErrors(in: bindings).isEmpty else { return false }
        var overrides: [String: Override] = [:]
        for action in AppAction.allCases where bindings[action] != Keymap.standard[action] {
            overrides[action.preferenceID] = Override(shortcut: bindings[action])
        }
        guard let data = try? JSONEncoder().encode(overrides) else { return false }
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        self.bindings = bindings
        return true
    }

    static func validationErrors(in bindings: [AppAction: Shortcut]) -> [AppAction: String] {
        var errors: [AppAction: String] = [:]
        for action in AppAction.allCases {
            guard let shortcut = bindings[action] else { continue }
            if let reason = invalidReason(for: shortcut) {
                errors[action] = reason
            } else if let other = AppAction.allCases.first(where: { $0 != action && bindings[$0] == shortcut }) {
                errors[action] = "Also assigned to \(other.helpTitle)."
            }
        }
        return errors
    }

    static func invalidReason(for shortcut: Shortcut) -> String? {
        guard shortcut.modifiers.contains(.command) else {
            return "Include Command (⌘) in the shortcut."
        }
        if case .char(let character) = shortcut.key,
           character.unicodeScalars.contains(where: {
               CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
           }) {
            return "Use a letter, number, symbol or arrow key with Command (⌘)."
        }
        if let name = reserved[shortcut] {
            return "Reserved for \(name)."
        }
        return nil
    }

    // AppKit's standard menu actions are outside AppAction. Letting an app
    // override shadow them would also break editing in sheets and settings.
    private static let reserved: [Shortcut: String] = [
        Shortcut(key: .char("q"), modifiers: .command): "Quit",
        Shortcut(key: .char("h"), modifiers: .command): "Hide",
        Shortcut(key: .char("h"), modifiers: [.command, .option]): "Hide Others",
        Shortcut(key: .char("m"), modifiers: .command): "Minimize",
        Shortcut(key: .char(","), modifiers: .command): "Settings",
        Shortcut(key: .char("x"), modifiers: .command): "Cut",
        Shortcut(key: .char("c"), modifiers: .command): "Copy",
        Shortcut(key: .char("v"), modifiers: .command): "Paste",
        Shortcut(key: .char("a"), modifiers: .command): "Select All",
        Shortcut(key: .char("z"), modifiers: .command): "Undo",
        Shortcut(key: .char("z"), modifiers: [.command, .shift]): "Redo",
        Shortcut(key: .char(" "), modifiers: .command): "Spotlight",
        Shortcut(key: .char(" "), modifiers: [.command, .control]): "Emoji & Symbols",
    ]
}
