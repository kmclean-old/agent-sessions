import Foundation

struct HarnessEvent: Equatable {
    var agent: String
    var runID: String
    var conversationID: String?
    var event: String
    var processID: Int32?
    var turnID: String?
    var requestID: String?
    var message: String?
    var outcome: String?
    var toolName: String?
    var notificationType: String?
    var willContinue: Bool
    var isInterrupt: Bool
    var sequence: UInt64?
    var source: String?

    init(
        agent: String,
        runID: String,
        conversationID: String? = nil,
        event: String,
        processID: Int32? = nil,
        turnID: String? = nil,
        requestID: String? = nil,
        message: String? = nil,
        outcome: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        willContinue: Bool = false,
        isInterrupt: Bool = false,
        sequence: UInt64? = nil,
        source: String? = nil
    ) {
        self.agent = agent
        self.runID = runID
        self.conversationID = conversationID
        self.event = event
        self.processID = processID
        self.turnID = turnID
        self.requestID = requestID
        self.message = message
        self.outcome = outcome
        self.toolName = toolName
        self.notificationType = notificationType
        self.willContinue = willContinue
        self.isInterrupt = isInterrupt
        self.sequence = sequence
        self.source = source
    }
}

enum HarnessPhase: String, Equatable {
    case unknown
    case idle
    case working
    case blocked
}

enum HarnessOutcome: String, Equatable {
    case completed
    case interrupted
    case failed
}

enum HarnessTransition: Equatable {
    case register(initial: HarnessPhase, preservingWork: Bool = false)
    case working
    case blocked(id: String, reason: String?)
    case aliasedBlocked(id: String, reason: String?, genericID: String, identifiedPrefix: String)
    case resolved(id: String)
    case resolvedMany(ids: [String])
    case resetConversation
    case settled(outcome: HarnessOutcome)
    case exited
}

protocol HarnessAdapter {
    var id: String { get }
    func transition(for event: HarnessEvent) -> HarnessTransition?
    func transition(forTitle title: String) -> HarnessTransition?
}

extension HarnessAdapter {
    func transition(forTitle title: String) -> HarnessTransition? { nil }
}

struct ClaudeHarnessAdapter: HarnessAdapter {
    let id = "claude"

    func transition(for event: HarnessEvent) -> HarnessTransition? {
        switch event.event {
        case "SessionStart": return .register(initial: .idle, preservingWork: event.source == "compact")
        case "UserPromptSubmit": return .working
        case "PreToolUse" where isQuestionTool(event.toolName):
            return .blocked(id: blockerID("question", event.requestID), reason: event.message)
        case "PreToolUse": return .working
        case "PostToolUse" where isQuestionTool(event.toolName):
            return questionResolved(event)
        case "PostToolUse": return .resolved(id: blockerID("permission", event.requestID))
        case "PostToolUseFailure" where event.isInterrupt:
            return .settled(outcome: .interrupted)
        case "PostToolUseFailure" where isQuestionTool(event.toolName):
            return questionResolved(event)
        case "PostToolUseFailure": return .resolved(id: blockerID("permission", event.requestID))
        case "PermissionRequest":
            return permissionBlocked(event)
        case "Notification" where event.notificationType == "permission_prompt":
            return permissionBlocked(event)
        case "Notification" where event.notificationType == "idle_prompt": return nil
        case "Stop" where event.willContinue: return .working
        case "Stop": return .settled(outcome: event.isInterrupt ? .interrupted : .completed)
        case "Interrupt": return .settled(outcome: .interrupted)
        case "StopFailure": return .settled(outcome: .failed)
        case "SessionEnd" where ["clear", "resume"].contains(event.source?.lowercased() ?? ""):
            return .resetConversation
        case "SessionEnd": return .exited
        default: return canonicalTransition(for: event)
        }
    }
}

struct CodexHarnessAdapter: HarnessAdapter {
    static let titlePermissionID = "permission"
    let id = "codex"

    func transition(for event: HarnessEvent) -> HarnessTransition? {
        ClaudeHarnessAdapter().transition(for: event)
    }

    func transition(forTitle title: String) -> HarnessTransition? {
        for prefix in ["[ ! ] Action Required", "[ . ] Action Required"] {
            if title == prefix || title.hasPrefix(prefix + " ") {
                return .blocked(id: Self.titlePermissionID, reason: nil)
            }
        }
        let parts = title.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, first.count == 1,
              "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) else { return nil }
        return .resolved(id: Self.titlePermissionID)
    }
}

struct OMPHarnessAdapter: HarnessAdapter {
    let id = "omp"

    func transition(for event: HarnessEvent) -> HarnessTransition? {
        switch event.event {
        case "session_start", "session_switch": return .register(initial: .idle)
        case "agent_start": return .working
        case "agent_end":
            if event.willContinue { return .working }
            return .settled(outcome: parsedOutcome(event.outcome, interrupt: event.isInterrupt))
        case "tool_approval_requested":
            return .blocked(id: event.requestID ?? "approval", reason: event.message)
        case "tool_approval_resolved": return .resolved(id: event.requestID ?? "approval")
        case "tool_execution_start" where event.toolName == "ask":
            return .blocked(id: event.requestID ?? "ask", reason: event.message)
        case "tool_execution_end" where event.toolName == "ask": return .resolved(id: event.requestID ?? "ask")
        case "tool_execution_start", "tool_execution_end", "auto_retry_start", "auto_retry_end": return .working
        case "session_shutdown": return .exited
        default: return canonicalTransition(for: event)
        }
    }
}

struct CanonicalHarnessAdapter: HarnessAdapter {
    let id: String

    func transition(for event: HarnessEvent) -> HarnessTransition? {
        canonicalTransition(for: event)
    }
}

struct HarnessAdapterRegistry {
    private let adapters: [String: any HarnessAdapter]

    init(adapters: [any HarnessAdapter] = [
        ClaudeHarnessAdapter(), CodexHarnessAdapter(), OMPHarnessAdapter()
    ]) {
        var indexed: [String: any HarnessAdapter] = [:]
        for adapter in adapters { indexed[adapter.id.lowercased()] = adapter }
        self.adapters = indexed
    }

    func adapter(for agent: String) -> any HarnessAdapter {
        adapters[agent.lowercased()] ?? CanonicalHarnessAdapter(id: agent.lowercased())
    }
}

private func parsedOutcome(_ value: String?, interrupt: Bool) -> HarnessOutcome {
    if interrupt { return .interrupted }
    switch value?.lowercased() {
    case "interrupted", "cancelled", "canceled": return .interrupted
    case "failed", "error": return .failed
    default: return .completed
    }
}

private func canonicalTransition(for event: HarnessEvent) -> HarnessTransition? {
    switch event.event.lowercased() {
    case "registered": return .register(initial: .idle)
    case "working": return .working
    case "blocked": return .blocked(id: event.requestID ?? "blocked", reason: event.message)
    case "resolved": return .resolved(id: event.requestID ?? "blocked")
    case "settled": return .settled(outcome: parsedOutcome(event.outcome, interrupt: event.isInterrupt))
    case "exited": return .exited
    default: return nil
    }
}

private func blockerID(_ kind: String, _ requestID: String?) -> String {
    requestID.map { "\(kind):\($0)" } ?? kind
}

private func isQuestionTool(_ toolName: String?) -> Bool {
    toolName == "AskUserQuestion" || toolName == "request_user_input"
}

private func permissionBlocked(_ event: HarnessEvent) -> HarnessTransition {
    .aliasedBlocked(
        id: blockerID("permission", event.requestID), reason: event.message,
        genericID: "permission", identifiedPrefix: "permission:"
    )
}

private func questionResolved(_ event: HarnessEvent) -> HarnessTransition {
    .resolvedMany(ids: [
        blockerID("question", event.requestID), blockerID("permission", event.requestID)
    ])
}
