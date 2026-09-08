import AppKit
import Combine

/// A sheet owns its draft. Closing without Save simply discards this object.
@MainActor
final class ShortcutEditor: ObservableObject {
    @Published var bindings: [AppAction: Shortcut]
    @Published private(set) var recordingError: String?

    init(bindings: [AppAction: Shortcut]) {
        self.bindings = bindings
    }

    var errors: [AppAction: String] { ShortcutPreferences.validationErrors(in: bindings) }

    func record(_ event: NSEvent, for action: AppAction, capture: ShortcutCapture) {
        guard let shortcut = Shortcut(event: event) else {
            recordingError = "Use a letter, number, symbol or arrow key."
            return
        }
        if let reason = ShortcutPreferences.invalidReason(for: shortcut) {
            recordingError = reason
            return
        }
        bindings[action] = shortcut
        recordingError = nil
        capture.end()
    }

    func clearRecordingError() { recordingError = nil }

    func reset(_ action: AppAction) {
        bindings[action] = Keymap.standard[action]
    }
}
