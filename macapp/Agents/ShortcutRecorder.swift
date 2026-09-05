import AppKit
import SwiftUI

/// Shared by the recorder, event monitor and action dispatcher. AppKit can
/// dispatch a menu equivalent even after a local monitor consumes the event,
/// so remember the captured keydown after recording ends as well.
@MainActor
final class ShortcutCapture: ObservableObject {
    @Published private(set) var action: AppAction?
    private weak var owner: NSView?
    private var receive: ((NSEvent) -> Void)?
    private var lastCaptured: NSEvent?
    private var heldKeys: [UInt16: Int] = [:]

    func begin(action: AppAction, owner: NSView, receive: @escaping (NSEvent) -> Void) {
        end()
        guard let window = owner.window, window.makeFirstResponder(owner) else { return }
        self.owner = owner
        self.receive = receive
        self.action = action
    }

    func end() {
        action = nil
        owner = nil
        receive = nil
    }

    func end(for view: NSView) {
        if owner === view { end() }
    }

    func suppresses(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if let lastCaptured,
           lastCaptured.timestamp == event.timestamp,
           lastCaptured.windowNumber == event.windowNumber,
           lastCaptured.keyCode == event.keyCode { return true }
        if event.isARepeat && heldKeys[event.keyCode] == event.windowNumber { return true }
        guard let owner, let window = owner.window else { return false }
        return action != nil && window === event.window && window.firstResponder === owner
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            return heldKeys.removeValue(forKey: event.keyCode) != nil
        }
        guard event.type == .keyDown, suppresses(event) else { return false }
        // The native responder can see a keydown already consumed by the
        // monitor. Never record the same event twice.
        if let lastCaptured, lastCaptured.timestamp == event.timestamp,
           lastCaptured.windowNumber == event.windowNumber,
           lastCaptured.keyCode == event.keyCode { return true }
        lastCaptured = event
        heldKeys[event.keyCode] = event.windowNumber
        guard !event.isARepeat else { return true }
        if event.keyCode == 53 && event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty {
            end()
        } else {
            receive?(event)
        }
        return true
    }
}

/// An actual first responder lets recording take precedence over both menu
/// key equivalents and normal text input, with native focus/accessibility.
struct ShortcutRecorder: NSViewRepresentable {
    let action: AppAction
    let shortcut: Shortcut?
    @ObservedObject var capture: ShortcutCapture
    let onRecord: (NSEvent) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = button
        button.action = #selector(ShortcutRecorderButton.startRecording)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.capture = capture
        button.shortcutAction = action
        button.onRecord = onRecord
        let recording = capture.action == action
        button.title = recording ? "Type shortcut…" : shortcut?.displayString ?? "Record Shortcut"
        button.setAccessibilityLabel("\(action.helpTitle) shortcut")
        button.setAccessibilityValue(recording ? "Recording" : shortcut?.displayString ?? "Not assigned")
        button.toolTip = "Click, then type a shortcut containing Command (⌘). Escape cancels recording."
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.capture?.end(for: button)
    }
}

final class ShortcutRecorderButton: NSButton {
    weak var capture: ShortcutCapture?
    var shortcutAction: AppAction = .newSession
    var onRecord: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    @objc func startRecording() {
        capture?.begin(action: shortcutAction, owner: self) { [weak self] event in
            self?.onRecord?(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if capture?.handle(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if capture?.handle(event) == true { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        capture?.end(for: self)
        return super.resignFirstResponder()
    }
}
