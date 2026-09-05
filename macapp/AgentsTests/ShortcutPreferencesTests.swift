import AppKit
import XCTest
@testable import Agents

@MainActor
final class ShortcutPreferencesTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "ShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }

    func test_saveReloadClearAndReset() {
        withDefaults { defaults in
            let preferences = ShortcutPreferences(defaults: defaults)
            XCTAssertEqual(preferences.bindings, Keymap.standard)
            var draft = preferences.bindings
            draft[.newSession] = Shortcut(key: .char("j"), modifiers: [.command, .shift])
            draft[.closeSession] = nil
            draft[.archiveProject] = Shortcut(key: .leftArrow, modifiers: [.command, .shift])
            XCTAssertEqual(preferences.bindings, Keymap.standard, "Draft edits must not apply before Save")
            XCTAssertTrue(preferences.save(draft))
            XCTAssertEqual(ShortcutPreferences(defaults: defaults).bindings, draft)
            XCTAssertTrue(preferences.save(Keymap.standard))
            XCTAssertNil(defaults.object(forKey: ShortcutPreferences.defaultsKey))
            XCTAssertEqual(ShortcutPreferences(defaults: defaults).bindings, Keymap.standard)
        }
    }

    func test_conflictsAreNamedAndSaveIsAtomic() {
        withDefaults { defaults in
            let preferences = ShortcutPreferences(defaults: defaults)
            var draft = preferences.bindings
            draft[.newSession] = draft[.closeSession]
            let errors = ShortcutPreferences.validationErrors(in: draft)
            XCTAssertTrue(errors[.newSession]!.contains("Close Session"))
            XCTAssertTrue(errors[.closeSession]!.contains("New Session"))
            XCTAssertFalse(preferences.save(draft))
            XCTAssertEqual(preferences.bindings, Keymap.standard)
            XCTAssertNil(defaults.object(forKey: ShortcutPreferences.defaultsKey))
            draft[.closeSession] = Keymap.standard[.newSession]
            XCTAssertTrue(preferences.save(draft), "Swapping two bindings is valid when saved together")
        }
    }

    func test_invalidAndReservedShortcutsAreRejected() {
        for shortcut in [
            Shortcut(key: .char("t"), modifiers: []),
            Shortcut(key: .char("c"), modifiers: .command),
            Shortcut(key: .char("q"), modifiers: .command),
            Shortcut(key: .char("\r"), modifiers: .command),
        ] {
            XCTAssertNotNil(ShortcutPreferences.invalidReason(for: shortcut))
        }
        XCTAssertNil(ShortcutPreferences.invalidReason(for: Shortcut(key: .char("j"), modifiers: [.command, .control])))
    }

    func test_corruptPreferencesFallBackAndUnknownActionsAreIgnored() {
        withDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: ShortcutPreferences.defaultsKey)
            XCTAssertEqual(ShortcutPreferences(defaults: defaults).bindings, Keymap.standard)
            defaults.set(Data(#"{"futureAction":{},"newSession":{}}"#.utf8), forKey: ShortcutPreferences.defaultsKey)
            var expected = Keymap.standard
            expected[.newSession] = nil
            XCTAssertEqual(ShortcutPreferences(defaults: defaults).bindings, expected)
        }
    }

    func test_preferenceIDsAreUniqueAndSessionSlotsAreStable() {
        XCTAssertEqual(Set(AppAction.allCases.map(\.preferenceID)).count, AppAction.allCases.count)
        XCTAssertEqual(AppAction.selectSession(0).preferenceID, "selectSession.1")
        XCTAssertEqual(AppAction.selectSession(8).preferenceID, "selectSession.9")
    }

    func test_shortcutsRoundTripWithNormalizedModifiersAndCase() throws {
        let shortcuts = Array(Keymap.standard.values) + [Shortcut(key: .char("J"), modifiers: [.command, .capsLock])]
        for shortcut in shortcuts {
            XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut)), shortcut)
        }
        XCTAssertEqual(shortcuts.last, Shortcut(key: .char("j"), modifiers: .command))
    }
}
