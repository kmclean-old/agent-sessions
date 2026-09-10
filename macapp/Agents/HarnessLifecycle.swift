import Foundation

struct PaneLifecycle: Equatable {
    var agent: String?
    var runID: String?
    var conversationID: String?
    var phase: HarnessPhase
    var blockers: [String: String?]
    var attended: Bool
    var completionCount: UInt64
    var seenCompletionCount: UInt64
    var outcome: HarnessOutcome?
    var since: Date?
    var retiredRunIDs: Set<String>
    var lastSequence: UInt64?
    var settledTurnIDs: Set<String>

    init(
        agent: String? = nil,
        runID: String? = nil,
        conversationID: String? = nil,
        phase: HarnessPhase = .unknown,
        blockers: [String: String?] = [:],
        attended: Bool = false,
        completionCount: UInt64 = 0,
        seenCompletionCount: UInt64 = 0,
        outcome: HarnessOutcome? = nil,
        since: Date? = nil,
        retiredRunIDs: Set<String> = [],
        lastSequence: UInt64? = nil,
        settledTurnIDs: Set<String> = []
    ) {
        self.agent = agent
        self.runID = runID
        self.conversationID = conversationID
        self.phase = phase
        self.blockers = blockers
        self.attended = attended
        self.completionCount = completionCount
        self.seenCompletionCount = seenCompletionCount
        self.outcome = outcome
        self.since = since
        self.retiredRunIDs = retiredRunIDs
        self.lastSequence = lastSequence
        self.settledTurnIDs = settledTurnIDs
    }

    var hasAgent: Bool { runID != nil }
    var unseenCompletion: Bool { completionCount > seenCompletionCount }
}

enum HarnessLifecycle {
    static func accepts(
        _ state: PaneLifecycle,
        event: HarnessEvent,
        adapter: any HarnessAdapter
    ) -> Bool {
        guard let transition = adapter.transition(for: event) else { return false }
        if state.retiredRunIDs.contains(event.runID) { return false }
        if let activeRun = state.runID, activeRun != event.runID {
            if case .register = transition { return true }
            return false
        }
        if state.runID == event.runID,
           let sequence = event.sequence,
           let lastSequence = state.lastSequence,
           sequence <= lastSequence { return false }
        if !isRegistration(transition),
           let activeConversation = state.conversationID,
           let eventConversation = event.conversationID,
           activeConversation != eventConversation { return false }
        if let turnID = event.turnID, state.settledTurnIDs.contains(turnID),
           !isRegistration(transition) { return false }
        return true
    }

    static func reduce(
        _ state: PaneLifecycle,
        event: HarnessEvent,
        adapter: any HarnessAdapter,
        at date: Date
    ) -> PaneLifecycle {
        guard accepts(state, event: event, adapter: adapter),
              let transition = adapter.transition(for: event) else { return state }

        var next = state
        if state.runID != event.runID {
            if let oldRun = state.runID { next.retiredRunIDs.insert(oldRun) }
            attach(&next, event: event)
        } else if state.runID == nil {
            attach(&next, event: event)
        }

        if let sequence = event.sequence { next.lastSequence = sequence }

        if case .register(let initial, let preservingWork) = transition {
            let conversationChanged = next.conversationID != nil
                && event.conversationID != nil
                && next.conversationID != event.conversationID
            if conversationChanged && !preservingWork {
                next.blockers = [:]
                next.settledTurnIDs = []
                next.outcome = nil
                next.completionCount = 0
                next.seenCompletionCount = 0
                next.phase = .unknown
                setPhase(&next, initial, at: date)
            } else if state.runID != event.runID || state.runID == nil {
                setPhase(&next, initial, at: date)
            }
            if let conversationID = event.conversationID {
                next.conversationID = conversationID
            }
            return next
        }

        switch transition {
        case .register:
            break
        case .working:
            next.outcome = nil
            if next.blockers.isEmpty { setPhase(&next, .working, at: date) }
        case .blocked(let id, let reason):
            next.blockers[id] = .some(reason)
            next.outcome = nil
            setPhase(&next, .blocked, at: date)
        case .aliasedBlocked(let id, let reason, let genericID, let identifiedPrefix):
            if id == genericID, next.blockers.keys.contains(where: { $0.hasPrefix(identifiedPrefix) }) {
                return next
            }
            if id.hasPrefix(identifiedPrefix) { next.blockers.removeValue(forKey: genericID) }
            next.blockers[id] = .some(reason)
            next.outcome = nil
            setPhase(&next, .blocked, at: date)
        case .resolved(let id):
            next.blockers.removeValue(forKey: id)
            if next.blockers.isEmpty { setPhase(&next, .working, at: date) }
        case .resolvedMany(let ids):
            for id in ids { next.blockers.removeValue(forKey: id) }
            if next.blockers.isEmpty { setPhase(&next, .working, at: date) }
        case .resetConversation:
            next.conversationID = nil
            next.blockers = [:]
            next.completionCount = 0
            next.seenCompletionCount = 0
            next.outcome = nil
            next.settledTurnIDs = []
            setPhase(&next, .idle, at: date)
        case .settled(let outcome):
            let wasActive = next.phase == .working || next.phase == .blocked
            next.blockers = [:]
            next.outcome = outcome
            if let turnID = event.turnID { next.settledTurnIDs.insert(turnID) }
            setPhase(&next, .idle, at: date)
            if wasActive && outcome != .interrupted {
                next.completionCount += 1
                if next.attended { next.seenCompletionCount = next.completionCount }
            }
        case .exited:
            return endRun(next, at: date)
        }
        return next
    }

    static func observeTitle(
        _ state: PaneLifecycle,
        title: String,
        adapter: any HarnessAdapter,
        at date: Date
    ) -> PaneLifecycle {
        guard state.hasAgent, let transition = adapter.transition(forTitle: title) else { return state }
        var next = state
        switch transition {
        case .blocked(let id, let reason):
            next.blockers[id] = .some(reason)
            setPhase(&next, .blocked, at: date)
        case .aliasedBlocked(let id, let reason, let genericID, let identifiedPrefix):
            if id == genericID, next.blockers.keys.contains(where: { $0.hasPrefix(identifiedPrefix) }) {
                return next
            }
            if id.hasPrefix(identifiedPrefix) { next.blockers.removeValue(forKey: genericID) }
            next.blockers[id] = .some(reason)
            setPhase(&next, .blocked, at: date)
        case .resolved(let id):
            next.blockers.removeValue(forKey: id)
            if next.blockers.isEmpty { setPhase(&next, .working, at: date) }
        case .resolvedMany(let ids):
            for id in ids { next.blockers.removeValue(forKey: id) }
            if next.blockers.isEmpty { setPhase(&next, .working, at: date) }
        case .resetConversation:
            break
        default:
            break
        }
        return next
    }

    static func setAttended(_ state: PaneLifecycle, _ attended: Bool) -> PaneLifecycle {
        var next = state
        next.attended = attended
        if attended { next.seenCompletionCount = next.completionCount }
        return next
    }

    static func endRun(_ state: PaneLifecycle, at date: Date) -> PaneLifecycle {
        guard let runID = state.runID else { return state }
        var next = state
        next.retiredRunIDs.insert(runID)
        next.agent = nil
        next.runID = nil
        next.conversationID = nil
        next.blockers = [:]
        next.lastSequence = nil
        next.settledTurnIDs = []
        next.phase = .idle
        next.since = date
        return next
    }

    private static func attach(_ state: inout PaneLifecycle, event: HarnessEvent) {
        state.agent = event.agent.lowercased()
        state.runID = event.runID
        state.conversationID = event.conversationID
        state.blockers = [:]
        state.outcome = nil
        state.completionCount = 0
        state.seenCompletionCount = 0
        state.phase = .unknown
        state.lastSequence = nil
        state.settledTurnIDs = []
    }

    private static func setPhase(_ state: inout PaneLifecycle, _ phase: HarnessPhase, at date: Date) {
        guard state.phase != phase else { return }
        state.phase = phase
        state.since = date
    }

    private static func isRegistration(_ transition: HarnessTransition) -> Bool {
        if case .register = transition { return true }
        return false
    }
}
