import AppKit
import SwiftUI
import XCTest
@testable import Agents

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private final class KeySink: NSView {
        var received = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received += 1 }
    }

    private final class MenuTarget: NSObject {
        let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
        @objc func invoke(_ sender: Any?) { perform() }
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
        let actions = AppActions(store: store, uiState: uiState, currentEvent: { key }, suppressShortcut: { capture.handle($0) })
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
            event(in: window, characters: "h", modifiers: .control, keyCode: 4, timestamp: 3),
            event(in: window, characters: "\u{F702}", modifiers: .option, keyCode: 123, timestamp: 4),
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

    func test_recordingCapturesApplicationEventsWithoutAppRouter() {
        let (window, button, capture, editor) = fixture()
        defer { window.close() }
        var recorded = 0
        button.onRecord = {
            recorded += 1
            editor.record($0, for: .renameSession, capture: capture)
        }
        button.startRecording()
        button.startRecording()
        let key = event(in: window, characters: "J", modifiers: [.command, .shift], keyCode: 38)

        NSApp.sendEvent(key)

        XCTAssertNil(capture.action)
        XCTAssertEqual(editor.bindings[.renameSession], Shortcut(key: .char("j"), modifiers: [.command, .shift]))
        XCTAssertEqual(recorded, 1, "Restarting capture must not leave duplicate listeners")
    }

    func test_recorderListenerReleasesInputWhenFocusMoves() {
        let (window, _, capture, editor) = fixture()
        defer { window.close() }
        let sink = KeySink()
        window.contentView!.addSubview(sink)
        XCTAssertTrue(window.makeFirstResponder(sink))
        XCTAssertNil(capture.action)
        var passedThrough = 0
        let observer = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in
            passedThrough += 1
            return nil
        }!
        defer { NSEvent.removeMonitor(observer) }

        NSApp.sendEvent(event(in: window, modifiers: []))

        XCTAssertEqual(passedThrough, 1)
        XCTAssertEqual(editor.bindings, Keymap.standard)
    }

    func test_hostedEditorRecordsCommandShortcutAfterInvalidAttempt() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = ShortcutPreferences(defaults: defaults)
        let capture = ShortcutCapture()
        let hosting = NSHostingView(rootView: ShortcutHelpView(preferences: preferences, capture: capture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        func recorders(in view: NSView) -> [ShortcutRecorderButton] {
            (view as? ShortcutRecorderButton).map { [$0] } ?? view.subviews.flatMap { recorders(in: $0) }
        }

        let button = try XCTUnwrap(recorders(in: hosting).first { $0.shortcutAction == .focusPaneLeft })
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.action, .focusPaneLeft)
        XCTAssertTrue(window.firstResponder === button)
        XCTAssertEqual(button.title, "Type shortcut…")

        XCTAssertTrue(window.performKeyEquivalent(with: event(in: window, modifiers: [])))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.action, .focusPaneLeft)
        XCTAssertTrue(window.firstResponder === button)

        let shortcut = event(in: window, characters: "j", modifiers: [.command, .shift], keyCode: 38, timestamp: 2)
        XCTAssertTrue(window.performKeyEquivalent(with: shortcut))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(capture.action)
        XCTAssertEqual(button.title, Shortcut(key: .char("j"), modifiers: [.command, .shift]).displayString)

        let router = ShortcutRouter(
            perform: { _ in XCTFail("Recording must precede actions"); return true },
            isModalActive: { false }, capture: { capture.handle($0) }
        )
        router.install()
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        let arrow = event(in: window, characters: "\u{F702}", modifiers: [.command, .control], keyCode: 123, timestamp: 3)
        withExtendedLifetime(router) { NSApp.sendEvent(arrow) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(capture.action)
        XCTAssertEqual(button.title, Shortcut(key: .leftArrow, modifiers: [.command, .control]).displayString)
    }

    func test_menuKeyEquivalentRecordsBeforeLocalMonitorReceivesEvent() {
        let (window, button, capture, editor) = fixture()
        defer { window.close() }
        var recorded = 0
        button.onRecord = {
            recorded += 1
            editor.record($0, for: .renameSession, capture: capture)
        }
        let key = event(in: window)
        let (store, _, _) = TestSupport.makeStore()
        let uiState = UIState()
        let actions = AppActions(store: store, uiState: uiState, currentEvent: { key }, suppressShortcut: { capture.handle($0) })
        let menu = NSMenu()
        let target = MenuTarget { actions.perform(.showShortcutHelp) }
        let item = NSMenuItem(title: "Show Shortcuts", action: #selector(MenuTarget.invoke(_:)), keyEquivalent: "t")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        XCTAssertTrue(menu.performKeyEquivalent(with: key))
        XCTAssertFalse(uiState.showShortcutHelp)
        XCTAssertNil(capture.action, "A menu that receives the key first must also finish recording")
        XCTAssertEqual(editor.bindings[.renameSession], Keymap.standard[.newSession])
        XCTAssertTrue(capture.handle(key))
        XCTAssertTrue(menu.performKeyEquivalent(with: key))
        XCTAssertEqual(recorded, 1)
        XCTAssertFalse(uiState.showShortcutHelp)
    }

    private final class SheetState: ObservableObject {
        @Published var show = false
    }

    private struct SheetHost: View {
        @ObservedObject var state: SheetState
        let preferences: ShortcutPreferences
        let capture: ShortcutCapture

        var body: some View {
            Color.clear.sheet(isPresented: $state.show) {
                ShortcutHelpView(preferences: preferences, capture: capture)
            }
        }
    }

    func test_swiftUISheetRecordsPostedCommandEvent() async throws {
        let state = SheetState()
        let preferences = ShortcutPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let capture = ShortcutCapture()
        let hosting = NSHostingView(rootView: SheetHost(state: state, preferences: preferences, capture: capture))
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: .titled, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = hosting
        parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        hosting.layoutSubtreeIfNeeded()
        state.show = true
        try await Task.sleep(for: .milliseconds(300))
        let sheet = try XCTUnwrap(parent.attachedSheet)

        func recorders(in view: NSView) -> [ShortcutRecorderButton] {
            (view as? ShortcutRecorderButton).map { [$0] } ?? view.subviews.flatMap { recorders(in: $0) }
        }
        let button = try XCTUnwrap(recorders(in: sheet.contentView!).first { $0.shortcutAction == .focusPaneLeft })
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.action, .focusPaneLeft)
        XCTAssertTrue(sheet.firstResponder === button)

        let router = ShortcutRouter(perform: { _ in false }, capture: { capture.handle($0) })
        router.install()

        let flagsChanged = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 10, windowNumber: sheet.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        NSApp.postEvent(flagsChanged, atStart: true)
        let queuedFlags = try XCTUnwrap(NSApp.nextEvent(matching: .flagsChanged, until: Date().addingTimeInterval(0.5), inMode: .default, dequeue: true))
        NSApp.sendEvent(queuedFlags)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.action, .focusPaneLeft)
        XCTAssertTrue(sheet.firstResponder === button)

        let source = CGEventSource(stateID: .privateState)
        let cgKey = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 38, keyDown: true))
        cgKey.flags = [.maskCommand, .maskShift]
        let key = try XCTUnwrap(NSEvent(cgEvent: cgKey))
        XCTAssertNil(key.window)
        NSApp.postEvent(key, atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.5), inMode: .default, dequeue: true))
        withExtendedLifetime(router) { NSApp.sendEvent(queued) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(capture.action)
        XCTAssertEqual(button.title, Shortcut(key: .char("j"), modifiers: [.command, .shift]).displayString)
        state.show = false
    }
}
