import SwiftUI

/// Keyboard shortcut help, generated from the action catalog and the live
/// preferences so menu labels and this sheet always agree.
struct ShortcutHelpView: View {
    @EnvironmentObject private var shortcuts: ShortcutPreferences
    /// Section order for the sheet. Every `AppAction.helpGroup` value must
    /// appear here or its rows would silently vanish from the sheet —
    /// internal (not private) so `KeymapTests` can enforce exactly that.
    static let groupOrder = ["Sessions", "Panes", "Workspaces", "Projects", "Window", "Help"]

    private struct Row: Identifiable {
        let id: AppAction
        let title: String
        let shortcut: String
    }

    private func rows(in group: String) -> [Row] {
        AppAction.allCases.filter { $0.helpGroup == group }.map { action in
            Row(id: action, title: action.helpTitle, shortcut: shortcuts.bindings[action]?.displayString ?? "—")
        }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Keyboard Shortcuts")
                        .font(.title2)
                        .fontWeight(.semibold)

                    ForEach(Self.groupOrder, id: \.self) { group in
                        let groupRows = rows(in: group)
                        if !groupRows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(groupRows) { row in
                                        HStack {
                                            Text(row.title)
                                            Spacer(minLength: 32)
                                            Text(row.shortcut)
                                                .foregroundStyle(.secondary)
                                                .monospaced()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(32)
            }

            Divider()

            HStack {
                Spacer()
                // SwiftUI sheets only get Esc-dismiss when their content
                // contains a button with `.keyboardShortcut(.cancelAction)`
                // — there's no other way to opt a sheet into it. This button
                // exists to satisfy that requirement; it deliberately does
                // NOT go through Keymap/ShortcutRouter, because it's
                // sheet-contextual (only meaningful while this sheet is
                // open), not a global app shortcut.
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 440, minHeight: 380)
    }
}
