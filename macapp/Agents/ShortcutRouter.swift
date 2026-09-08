import AppKit

/// Routes app shortcuts and recording through one local event monitor.
/// Menus read the same effective bindings. A handled event must leave the
/// monitor as nil; optional chaining with `?? event` would accidentally
/// reintroduce it into menu and terminal dispatch.
///
/// Dialog presentation is deferred by AppActions: a modal loop must not run
/// while the triggering keydown is suspended inside this callback.
@MainActor
final class ShortcutRouter {
    private var monitor: Any?
    private let perform: (AppAction) -> Bool
    private let isModalActive: () -> Bool
    private let bindings: () -> [AppAction: Shortcut]
    private let capture: (NSEvent) -> Bool

    init(
        perform: @escaping (AppAction) -> Bool,
        isModalActive: @escaping () -> Bool = { NSApp.modalWindow != nil },
        bindings: @escaping () -> [AppAction: Shortcut] = { Keymap.standard },
        capture: @escaping (NSEvent) -> Bool = { _ in false }
    ) {
        self.perform = perform
        self.isModalActive = isModalActive
        self.bindings = bindings
        self.capture = capture
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Internal (not private) so AgentsTests can exercise the consume/pass-
    // through decision directly via @testable import, without needing a
    // real global NSEvent monitor or real NSApp modal state.
    func handle(_ event: NSEvent) -> NSEvent? {
        // Alerts/open panels own the keyboard while modal.
        if isModalActive() {
            return event
        }
        if capture(event) { return nil }
        guard event.type == .keyDown else { return event }
        // Plain typing, including Shift, belongs to the focused responder.
        guard !event.modifierFlags.intersection(Shortcut.requiredModifiers).isEmpty else {
            return event
        }
        guard let action = Keymap.action(for: event, in: bindings()) else {
            return event
        }
        if perform(action) {
            return nil // handled — swallow it here (the menu key-equivalent still fires; AppActions dedups that)
        }
        return event // action not currently valid (e.g. ⌘W with nothing selected) — let the system handle/beep normally
    }
}
