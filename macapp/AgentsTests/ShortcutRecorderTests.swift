import AppKit
import XCTest
@testable import Agents

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private final class KeySink: NSView {
        var received = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received += 1 }
    }

    private func event(
        in window: NSWindow,
        characters: String = "t",
        modifiers: NSEvent.ModifierFlags = .command,
        keyCode: UInt16 = 17,
        timestamp: TimeInterval = 1,
        repeatKey: Bool = false,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeatKey, keyCode: keyCode
        )!
    }

    private func fixture() -> (NSWindow, ShortcutRecorderButton, ShortcutCapture, ShortcutEditor) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecorderButton(frame: NSRect(x: 20, y: 20, width: 150, height: 30))
        window.contentView!.addSubview(button)
        let capture = ShortcutCapture()
        let editor = ShortcutEditor(bindings: Keymap.standard)
        button.capture = capture
        button.shortcutAction = .renameSession
        button.onRecord = { editor.record($0, for: .renameSession, capture: capture) }
        button.startRecording()
        XCTAssertEqual(capture.action, .renameSession)
        XCTAssertTrue(window.firstResponder === button)
        return (window, button, capture, editor)
    }

    func test_recordingConsumesRouterAndMenuDispatchEvenAfterRecordingEnds() {
        let (window, button, capture, editor) = fixture()
        defer { window.close() }
        var performed: [AppAction] = []
        let router = ShortcutRouter(
            perform: { performed.append($0); return true },
            isModalActive: { false }, capture: { capture.handle($0) }
        )
        let key = event(in: window)
        XCTAssertNil(router.handle(key))
        XCTAssertEqual(editor.bindings[.renameSession], Keymap.standard[.newSession])
        XCTAssertNil(capture.action)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertTrue(button.performKeyEquivalent(with: key), "The responder also consumes the captured menu equivalent")

        let (store, _, _) = TestSupport.makeStore()
        let uiState = UIState()
        let actions = AppActions(store: store, uiState: uiState, currentEvent: { key }, suppressShortcut: { capture.suppresses($0) })
        XCTAssertTrue(actions.perform(.showShortcutHelp))
        XCTAssertFalse(uiState.showShortcutHelp, "The menu's duplicate dispatch must not execute an action")
    }

    func test_escapeCancelsOnlyRecordingAndNextEscapePassesThrough() {
        let (window, _, capture, editor) = fixture()
        defer { window.close() }
        let escape = event(in: window, characters: "\u{1B}", modifiers: [], keyCode: 53)
        XCTAssertTrue(capture.handle(escape))
        XCTAssertNil(capture.action)
        XCTAssertEqual(editor.bindings, Keymap.standard)
        XCTAssertTrue(capture.suppresses(escape), "The sheet's cancel button must ignore this same Escape")
        XCTAssertFalse(capture.handle(event(in: window, characters: "\u{1B}", modifiers: [], keyCode: 53, timestamp: 2)))
    }

    func test_plainTypingAndReservedKeysStayInRecorderWithoutChangingDraft() {
        let (window, button, capture, editor) = fixture()
        defer { window.close() }
        XCTAssertTrue(button.performKeyEquivalent(with: event(in: window, modifiers: [])))
        XCTAssertEqual(capture.action, .renameSession)
        XCTAssertNotNil(editor.recordingError)
        XCTAssertTrue(button.performKeyEquivalent(with: event(in: window, characters: "q", keyCode: 12, timestamp: 2)))
        XCTAssertEqual(editor.recordingError, "Reserved for Quit.")
        XCTAssertEqual(editor.bindings, Keymap.standard)
        XCTAssertTrue(capture.handle(event(in: window, characters: "J", modifiers: [.command, .shift], keyCode: 38, timestamp: 3)))
        XCTAssertNil(editor.recordingError)
        XCTAssertNil(capture.action)
        XCTAssertEqual(editor.bindings[.renameSession], Shortcut(key: .char("j"), modifiers: [.command, .shift]))
    }

    func test_heldShortcutCannotExecuteAfterRecordingCompletes() {
        let (window, _, capture, _) = fixture()
        defer { window.close() }
        XCTAssertTrue(capture.handle(event(in: window)))
        XCTAssertNil(capture.action)
        XCTAssertTrue(capture.handle(event(in: window, timestamp: 2, repeatKey: true)))
        XCTAssertTrue(capture.handle(event(in: window, timestamp: 3, type: .keyUp)))
        XCTAssertFalse(capture.handle(event(in: window, timestamp: 4)))
    }

    func test_movingFocusEndsRecordingAndOtherWindowsAreUnaffected() {
        let (window, _, capture, _) = fixture()
        defer { window.close() }
        let other = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertFalse(capture.handle(event(in: other)))
        window.makeFirstResponder(nil)
        XCTAssertNil(capture.action)
        XCTAssertFalse(capture.handle(event(in: window)))
    }

    func test_shiftedPunctuationAndArrowsCaptureAndMatch() {
        let (window, button, capture, editor) = fixture()
        defer { window.close() }
        for (index, key) in [
            event(in: window, characters: "?", modifiers: [.command, .shift], keyCode: 44),
            event(in: window, characters: "\u{F702}", modifiers: [.command, .option, .shift], keyCode: 123, timestamp: 2),
        ].enumerated() {
            if index > 0 { button.startRecording() }
            XCTAssertTrue(capture.handle(key))
            XCTAssertTrue(editor.bindings[.renameSession]!.matches(key))
            XCTAssertNil(capture.action)
        }
    }

    func test_resetCanIntroduceConflictUntilOtherBindingIsCleared() {
        let editor = ShortcutEditor(bindings: Keymap.standard)
        editor.bindings[.newSession] = Keymap.standard[.closeSession]
        editor.bindings[.closeSession] = Keymap.standard[.newSession]
        XCTAssertTrue(editor.errors.isEmpty)
        editor.reset(.newSession)
        XCTAssertNotNil(editor.errors[.newSession])
        editor.bindings[.closeSession] = nil
        XCTAssertTrue(editor.errors.isEmpty)
    }

    func test_installedMonitorKeepsConsumedEventsOutOfTheResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sink = KeySink()
        window.contentView = sink
        window.makeFirstResponder(sink)
        var captured = 0
        let router = ShortcutRouter(perform: { _ in XCTFail("Recording must precede actions"); return true }, isModalActive: { false }, capture: { _ in
            captured += 1
            return true
        })
        router.install()
        withExtendedLifetime(router) {
            NSApp.sendEvent(event(in: window, modifiers: []))
        }
        XCTAssertEqual(captured, 1)
        XCTAssertEqual(sink.received, 0, "A nil handler result must remain nil at the installed monitor boundary")
    }
}
