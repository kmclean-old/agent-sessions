import Foundation

/// Native configuration adapters own hook entries; runtime adapters own events.
enum HarnessHookConfiguration {
    struct Result {
        let data: Data
        let entries: [String: Data]
        let isEmpty: Bool
        let notes: [String]
    }

    static func events(for harness: HarnessKind) -> [String] {
        switch harness {
        case .claude:
            return ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                    "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure"]
        case .codex:
            return ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                    "PostToolUse", "Stop", "Interrupt"]
        case .omp: return []
        }
    }

    static func prepare(data: Data?, harness: HarnessKind, command: String,
                        previous: [String: Data], remove: Bool, managedEmitterPaths: [String]) throws -> Result {
        let original: [String: Any]
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HarnessSetupError(message: "Harness configuration must be a JSON object.")
            }
            original = object
        } else { original = [:] }
        var result = original
        var hooks: [String: Any] = [:]
        if let value = original["hooks"] {
            guard let dictionary = value as? [String: Any] else { throw invalid("hooks") }
            hooks = dictionary
        }
        let desired: [String: Any] = ["type": "command", "command": command]
        var entries: [String: Data] = [:]
        var migrated = false
        var preservedEdits = false
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [[String: Any]] else { throw invalid(event) }
            let prior = try previous[event].map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var retained: [[String: Any]] = []
            for var group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else { throw invalid(event) }
                var kept: [[String: Any]] = []
                var removed = false
                for hook in commands {
                    let hookCommand = hook["command"] as? String
                    let owned = prior.flatMap { $0 }.map { equal(hook, $0) } ?? false
                    let legacy = !remove && hook["type"] as? String == "command"
                        && hookCommand.map(isManualEmitterCommand) == true
                    // Adopt only an exact existing definition. An edited owned
                    // command needs user attention before repair can replace it.
                    let exactDesired = !remove && equal(hook, desired)
                    if owned || legacy || exactDesired {
                        removed = true
                        migrated = migrated || legacy
                    } else {
                        let referencesEmitter = hookCommand.map { candidate in
                            managedEmitterPaths.contains {
                                candidate.contains($0) || candidate.contains($0.replacingOccurrences(of: "'", with: "'\"'\"'"))
                            }
                        } ?? false
                        if remove && referencesEmitter { preservedEdits = true }
                        if !remove && (hookCommand == command || referencesEmitter) {
                            throw HarnessSetupError(message: "An Agents hook in \(event) was edited. Restore or remove that entry before repairing; unrelated hooks will be preserved.")
                        }
                        kept.append(hook)
                    }
                }
                if !removed { retained.append(group); continue }
                group["hooks"] = kept
                // A matcher or another user field can outlive the owned hook.
                if !kept.isEmpty || group.keys.contains(where: { $0 != "hooks" }) { retained.append(group) }
            }
            if retained.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        if !remove {
            let encoded = try encode(desired)
            for event in events(for: harness) {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [desired]])
                hooks[event] = groups
                entries[event] = encoded
            }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") }
        else { result["hooks"] = hooks }
        let output: Data
        if equal(result, original), let data { output = data }
        else { output = try encode(result) }
        var notes: [String] = []
        if migrated { notes.append("Existing checkout-based Agents hooks will be replaced with the installed emitter.") }
        if preservedEdits { notes.append("Edited Agents hooks will be preserved. They may continue reporting until you remove them from the harness configuration.") }
        return Result(data: output, entries: entries, isEmpty: result.isEmpty, notes: notes)
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return data
    }

    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private static func invalid(_ event: String) -> HarnessSetupError {
        HarnessSetupError(message: "Unrecognized hook configuration at \(event). No changes were prepared.")
    }

    /// Parse a single shell command without evaluating it. Only the documented
    /// checkout hook, optionally invoked with bash, is eligible for migration.
    static func isManualEmitterCommand(_ command: String) -> Bool {
        guard let words = shellWords(command) else { return false }
        let path: String
        if words.count == 1 { path = words[0] }
        else if words.count == 2, ["bash", "/bin/bash", "/usr/bin/bash"].contains(words[0]) { path = words[1] }
        else { return false }
        return path.hasPrefix("/") && path.hasSuffix("/hooks/agents-status.sh")
    }

    private static func shellWords(_ value: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var hasWord = false
        for character in value {
            if escaped { word.append(character); escaped = false; hasWord = true; continue }
            if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if quote == "\"" {
                if character == "\"" { quote = nil }
                else if character == "\\" { escaped = true }
                else if character == "$" || character == "`" { return nil }
                else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character; hasWord = true }
            else if character == "\\" { escaped = true; hasWord = true }
            else if character == "\n" || character == "\r" { return nil }
            else if character.isWhitespace {
                if hasWord { words.append(word); word = ""; hasWord = false }
            } else if ";|&<>$`(){}*?[]~\n\r".contains(character) { return nil }
            else { word.append(character); hasWord = true }
        }
        guard quote == nil, !escaped else { return nil }
        if hasWord { words.append(word) }
        return words
    }
}
