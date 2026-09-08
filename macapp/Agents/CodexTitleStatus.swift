import Foundation

/// Codex 0.153.4 replaces its title spinner with Action Required while a
/// prompt is open. This covers the gap between PermissionRequest and the
/// PostToolUse event, which can arrive only after a long command finishes.
/// See codex-rs/tui/src/chatwidget/status_surfaces.rs in openai/codex.
enum CodexTitleStatus {
    static func parse(_ title: String) -> SessionActivity.StatusMessage? {
        for prefix in ["[ ! ] Action Required", "[ . ] Action Required"] {
            if title == prefix || title.hasPrefix(prefix + " ") {
                return .set(.blocked)
            }
        }
        // Require a leading activity item; a spinner elsewhere may be title generation.
        let parts = title.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, first.count == 1,
              "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) else { return nil }
        return .clear
    }
}
