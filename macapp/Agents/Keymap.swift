import AppKit
import SwiftUI

/// Every user-invocable action in the app, expressed as data rather than a
/// scattered set of ad hoc handlers. `ShortcutPreferences` combines defaults
/// and user overrides; `ShortcutRouter`
/// and the app's menus both dispatch through `AppActions.perform(_:)`.
enum AppAction: Hashable {
    case newSession
    case closeSession
    case renameSession
    case closeWindow
    case addProject
    case archiveProject
    case removeProject
    case previousSession
    case nextSession
    case selectSession(Int)
    case newWorkspace
    case closeWorkspace
    case splitPaneRight
    case splitPaneDown
    case closePane
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case showShortcutHelp
}

extension AppAction: CaseIterable {
    /// `selectSession` carries an associated value, so Swift can't
    /// synthesize `CaseIterable` automatically — enumerate all 9 index
    /// cases (0...8, for the ⌘1–⌘9 bindings) explicitly alongside the
    /// simple cases.
    static var allCases: [AppAction] {
        [
            .newSession, .closeSession, .renameSession, .closeWindow, .addProject, .archiveProject, .removeProject,
            .previousSession, .nextSession, .newWorkspace, .closeWorkspace,
            .splitPaneRight, .splitPaneDown, .closePane,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .showShortcutHelp,
        ]
            + (0..<9).map { AppAction.selectSession($0) }
    }
}

extension AppAction {
    /// Stable preference keys, independent of display labels and enum ordering.
    var preferenceID: String {
        switch self {
        case .newSession: return "newSession"
        case .closeSession: return "closeSession"
        case .renameSession: return "renameSession"
        case .closeWindow: return "closeWindow"
        case .addProject: return "addProject"
        case .archiveProject: return "archiveProject"
        case .removeProject: return "removeProject"
        case .previousSession: return "previousSession"
        case .nextSession: return "nextSession"
        case .selectSession(let index): return "selectSession.\(index + 1)"
        case .newWorkspace: return "newWorkspace"
        case .closeWorkspace: return "closeWorkspace"
        case .splitPaneRight: return "splitPaneRight"
        case .splitPaneDown: return "splitPaneDown"
        case .closePane: return "closePane"
        case .focusPaneLeft: return "focusPaneLeft"
        case .focusPaneRight: return "focusPaneRight"
        case .focusPaneUp: return "focusPaneUp"
        case .focusPaneDown: return "focusPaneDown"
        case .showShortcutHelp: return "showShortcutHelp"
        }
    }

    /// Human-facing label for the shortcut editor.
    var helpTitle: String {
        switch self {
        case .newSession: return "New Session"
        case .closeSession: return "Close Session"
        case .renameSession: return "Rename Session…"
        case .closeWindow: return "Close Window"
        case .addProject: return "Add Project…"
        case .archiveProject: return "Archive Project"
        case .removeProject: return "Remove Project…"
        case .previousSession: return "Previous Session"
        case .nextSession: return "Next Session"
        case .selectSession(let index): return "Jump to Session \(index + 1)"
        case .newWorkspace: return "New Workspace"
        case .closeWorkspace: return "Close Workspace…"
        case .splitPaneRight: return "Split Pane Right"
        case .splitPaneDown: return "Split Pane Down"
        case .closePane: return "Close Pane"
        case .focusPaneLeft: return "Focus Pane Left"
        case .focusPaneRight: return "Focus Pane Right"
        case .focusPaneUp: return "Focus Pane Up"
        case .focusPaneDown: return "Focus Pane Down"
        case .showShortcutHelp: return "Keyboard Shortcuts"
        }
    }

    /// Which section of the shortcut-help sheet this action's row renders
    /// under. Sheet section order is fixed in `ShortcutHelpView`.
    var helpGroup: String {
        switch self {
        case .newSession, .closeSession, .renameSession, .previousSession, .nextSession, .selectSession:
            return "Sessions"
        case .splitPaneRight, .splitPaneDown, .closePane,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown:
            return "Panes"
        case .newWorkspace, .closeWorkspace:
            return "Workspaces"
        case .addProject, .archiveProject, .removeProject:
            return "Projects"
        case .closeWindow:
            return "Window"
        case .showShortcutHelp:
            return "Help"
        }
    }
}

/// A physical key combination: a key plus an exact set of modifier flags.
struct Shortcut: Hashable, Codable {
    enum Key: Hashable {
        case char(Character)
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
    }

    let key: Key
    let modifiers: NSEvent.ModifierFlags

    /// The only modifier bits Shortcut ever cares about. Matching always
    /// intersects against this set first so incidental flags (caps lock,
    /// numeric pad, function, ...) never break a match.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        if case .char(let character) = key {
            self.key = .char(Character(String(character).lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    /// Capture and matching share the same character semantics, including
    /// shifted punctuation (e.g. ⇧⌘/ arrives as "?") and arrow keys.
    init?(event: NSEvent) {
        let key: Key
        switch event.specialKey {
        case .upArrow: key = .upArrow
        case .downArrow: key = .downArrow
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1, let character = characters.first,
                  character.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                          && !(0xF700...0xF8FF).contains($0.value)
                  }) else { return nil }
            key = .char(character)
        }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .key)
        let key: Key
        switch name {
        case "upArrow": key = .upArrow
        case "downArrow": key = .downArrow
        case "leftArrow": key = .leftArrow
        case "rightArrow": key = .rightArrow
        default:
            guard name.hasPrefix("char:"), name.dropFirst(5).count == 1,
                  let character = name.dropFirst(5).first else {
                throw DecodingError.dataCorruptedError(forKey: .key, in: values, debugDescription: "Unknown shortcut key")
            }
            key = .char(character)
        }
        self.init(key: key, modifiers: NSEvent.ModifierFlags(rawValue: try values.decode(UInt.self, forKey: .modifiers)))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let name: String
        switch key {
        case .char(let character): name = "char:\(character)"
        case .upArrow: name = "upArrow"
        case .downArrow: name = "downArrow"
        case .leftArrow: name = "leftArrow"
        case .rightArrow: name = "rightArrow"
        }
        try values.encode(name, forKey: .key)
        try values.encode(modifiers.rawValue, forKey: .modifiers)
    }

    // NSEvent.ModifierFlags does not conform to Hashable, so Shortcut can't
    // derive Hashable automatically — implement it by hand over the
    // rawValue of the intersected (relevant-only) flags.
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.intersection(Self.relevantModifiers).rawValue)
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.key == rhs.key
            && lhs.modifiers.intersection(relevantModifiers) == rhs.modifiers.intersection(relevantModifiers)
    }

    /// Whether `event` exactly matches this shortcut: modifier flags must
    /// match EXACTLY over [.command, .shift, .option, .control] (so ⌘W
    /// never matches ⇧⌘W and vice versa), and the key must match.
    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(Self.relevantModifiers) == modifiers.intersection(Self.relevantModifiers) else {
            return false
        }
        switch key {
        case .char(let character):
            guard let characters = event.charactersIgnoringModifiers else { return false }
            return characters.lowercased() == String(character).lowercased()
        case .upArrow:
            return event.specialKey == .upArrow
        case .downArrow:
            return event.specialKey == .downArrow
        case .leftArrow:
            return event.specialKey == .leftArrow
        case .rightArrow:
            return event.specialKey == .rightArrow
        }
    }

    /// For SwiftUI menu display only — actual matching/consuming always
    /// goes through `matches(_:)` via `ShortcutRouter`.
    var swiftUIShortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
        let keyEquivalent: KeyEquivalent
        switch key {
        case .char(let character): keyEquivalent = KeyEquivalent(character)
        case .upArrow: keyEquivalent = .upArrow
        case .downArrow: keyEquivalent = .downArrow
        case .leftArrow: keyEquivalent = .leftArrow
        case .rightArrow: keyEquivalent = .rightArrow
        }

        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }

        return (keyEquivalent, eventModifiers)
    }

    /// Human-facing rendering for the shortcut-help sheet, e.g. "⌘T",
    /// "⇧⌘W", "⌥⌘↓", "⌘1". Glyph order follows the conventional ⌃⌥⇧⌘
    /// (control, option, shift, command) ordering.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .char(let character): result += String(character).uppercased()
        case .upArrow: result += "↑"
        case .downArrow: result += "↓"
        case .leftArrow: result += "←"
        case .rightArrow: result += "→"
        }
        return result
    }
}

/// Factory defaults. Runtime consumers use `ShortcutPreferences.bindings`,
/// which overlays persisted user choices on this table.
enum Keymap {
    static let standard: [AppAction: Shortcut] = {
        var map: [AppAction: Shortcut] = [
            .newSession: Shortcut(key: .char("t"), modifiers: [.command]),
            .closeSession: Shortcut(key: .char("w"), modifiers: [.command]),
            // ⇧⌘R, not plain ⌘R: ShortcutRouter intercepts every ⌘ event
            // globally before the hosted ghostty terminal sees it, so
            // binding plain ⌘R would permanently steal it from the terminal.
            .renameSession: Shortcut(key: .char("r"), modifiers: [.command, .shift]),
            .closeWindow: Shortcut(key: .char("w"), modifiers: [.command, .shift]),
            .addProject: Shortcut(key: .char("n"), modifiers: [.command, .shift]),
            .previousSession: Shortcut(key: .upArrow, modifiers: [.command, .option]),
            .nextSession: Shortcut(key: .downArrow, modifiers: [.command, .option]),
            .newWorkspace: Shortcut(key: .char("n"), modifiers: [.command]),
            // ⌘D / ⇧⌘D follow the iTerm2/Ghostty split convention. Close
            // Pane gets ⌥⌘W rather than overloading ⌘W: ⌘W closes the whole
            // session, and a modifier-distinct binding keeps "close the pane
            // I'm in" from ever being one slipped shift away from "kill the
            // session."
            .splitPaneRight: Shortcut(key: .char("d"), modifiers: [.command]),
            .splitPaneDown: Shortcut(key: .char("d"), modifiers: [.command, .shift]),
            .closePane: Shortcut(key: .char("w"), modifiers: [.command, .option]),
            // ⌃⌘ arrows: a full four-direction set that doesn't collide with
            // ⌥⌘↑/↓ (previous/next session). Pane focus and session switching
            // being different modifier pairs is deliberate — the two "move
            // around" gestures must never depend on which session is split.
            .focusPaneLeft: Shortcut(key: .leftArrow, modifiers: [.command, .control]),
            .focusPaneRight: Shortcut(key: .rightArrow, modifiers: [.command, .control]),
            .focusPaneUp: Shortcut(key: .upArrow, modifiers: [.command, .control]),
            .focusPaneDown: Shortcut(key: .downArrow, modifiers: [.command, .control]),
            .showShortcutHelp: Shortcut(key: .char("?"), modifiers: [.command, .shift]),
            // .archiveProject, .removeProject and .closeWorkspace intentionally have no entry: menu-only.
        ]
        for index in 0..<9 {
            let digit = Character("\(index + 1)")
            map[.selectSession(index)] = Shortcut(key: .char(digit), modifiers: [.command])
        }
        return map
    }()

    static func action(for event: NSEvent, in bindings: [AppAction: Shortcut] = standard) -> AppAction? {
        bindings.first { _, shortcut in shortcut.matches(event) }?.key
    }
}
