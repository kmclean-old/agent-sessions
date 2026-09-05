import SwiftUI

/// The existing help sheet doubles as a shortcut editor. All changes belong
/// to a draft until Save, including clears and restores.
struct ShortcutHelpView: View {
    static let groupOrder = ["Sessions", "Panes", "Workspaces", "Projects", "Window", "Help"]

    @ObservedObject private var preferences: ShortcutPreferences
    @ObservedObject private var capture: ShortcutCapture
    @StateObject private var editor: ShortcutEditor
    @Environment(\.dismiss) private var dismiss

    init(preferences: ShortcutPreferences, capture: ShortcutCapture) {
        self.preferences = preferences
        self.capture = capture
        _editor = StateObject(wrappedValue: ShortcutEditor(bindings: preferences.bindings))
    }

    var body: some View {
        let errors = editor.errors
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Click a shortcut, then press a new combination including Command (⌘).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Self.groupOrder, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(AppAction.allCases.filter { $0.helpGroup == group }, id: \.self) { action in
                                row(action, error: errors[action])
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if !errors.isEmpty {
                    Text("Resolve shortcut conflicts before saving.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Restore Defaults") {
                        capture.end()
                        editor.bindings = Keymap.standard
                    }
                    .disabled(editor.bindings == Keymap.standard)
                    Spacer()
                    Button("Cancel") {
                        guard !capture.suppresses(NSApp.currentEvent) else { return }
                        capture.end()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        guard !capture.suppresses(NSApp.currentEvent) else { return }
                        if preferences.save(editor.bindings) {
                            capture.end()
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty || capture.action != nil)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 650)
        .onChange(of: capture.action) { _, _ in editor.clearRecordingError() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            capture.end()
        }
        .onDisappear { capture.end() }
    }

    private func row(_ action: AppAction, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(action.helpTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorder(action: action, shortcut: editor.bindings[action], capture: capture) { event in
                    editor.record(event, for: action, capture: capture)
                }
                .frame(width: 156, height: 28)
                Button {
                    capture.end()
                    editor.bindings[action] = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .disabled(editor.bindings[action] == nil)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(action.helpTitle) shortcut")
                Button {
                    capture.end()
                    editor.reset(action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(editor.bindings[action] == Keymap.standard[action])
                .help("Restore default shortcut")
                .accessibilityLabel("Restore \(action.helpTitle) shortcut")
            }
            if let message = (capture.action == action ? editor.recordingError : nil) ?? error {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
