import Foundation

/// A read-only projection of the harnesses and attention in one app session.
struct SessionLifecycleSummary: Equatable {
    let panes: [UUID: PaneLifecycle]
    let attention: [UUID: AttentionState]

    var phase: HarnessPhase {
        let phases = panes.values.filter(\.hasAgent).map(\.phase)
        if phases.contains(.blocked) { return .blocked }
        if phases.contains(.working) { return .working }
        if phases.contains(.idle) { return .idle }
        return .unknown
    }

    var workingCount: Int { panes.values.filter { $0.hasAgent && $0.phase == .working }.count }
    var readyCount: Int { panes.values.filter { $0.hasAgent && $0.unseenCompletion }.count }

    var attentionPane: UUID? {
        attention.filter { $0.value.activity != nil }.sorted {
            let lhs = $0.value.activity == .blocked ? 0 : 1
            let rhs = $1.value.activity == .blocked ? 0 : 1
            if lhs != rhs { return lhs < rhs }
            let leftDate = $0.value.since ?? .distantFuture
            let rightDate = $1.value.since ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.key.uuidString < $1.key.uuidString
        }.first?.key
    }

    var activity: SessionActivity? { attentionPane.flatMap { attention[$0]?.activity } }
    var since: Date? { attentionPane.flatMap { attention[$0]?.since } }
    var reason: String? {
        guard let id = attentionPane, let state = panes[id] else { return nil }
        if state.phase == .blocked {
            return state.blockers.keys.sorted().compactMap { state.blockers[$0] ?? nil }.first
        }
        switch state.outcome {
        case .failed: return "Stopped with an error"
        case .completed: return "Done · ready to review"
        default: return nil
        }
    }
}
