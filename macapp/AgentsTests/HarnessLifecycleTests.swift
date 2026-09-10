import XCTest
@testable import Agents

final class HarnessLifecycleTests: XCTestCase {
    private let adapter = ClaudeHarnessAdapter()
    private let first = Date(timeIntervalSince1970: 10)
    private let later = Date(timeIntervalSince1970: 20)

    func testRegistrationStartsIdleWithoutFabricatingCompletion() {
        let event = HarnessEvent(agent: "claude", runID: "run-1", event: "SessionStart")
        let state = HarnessLifecycle.reduce(PaneLifecycle(), event: event, adapter: adapter, at: first)

        XCTAssertTrue(state.hasAgent)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.unseenCompletion)
        XCTAssertNil(state.outcome)
    }

    func testCompletionIsSeenWhenAttendedAndFocusNeverClearsBlocker() {
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(agent: "claude", runID: "run-1", event: "UserPromptSubmit"),
            adapter: adapter,
            at: first
        )
        state = HarnessLifecycle.setAttended(state, true)
        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "run-1", event: "Stop", turnID: "turn-1"),
            adapter: adapter,
            at: later
        )
        XCTAssertFalse(state.unseenCompletion)
        XCTAssertEqual(state.completionCount, 1)

        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(
                agent: "claude", runID: "run-1", event: "PermissionRequest",
                turnID: "turn-2", requestID: "permission-1"
            ),
            adapter: adapter,
            at: later
        )
        state = HarnessLifecycle.setAttended(state, true)
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertTrue(state.blockers.keys.contains("permission:permission-1"))
    }

    func testOnlyRegistrationCanReplaceOwnerAndRetiredRunCannotReturn() {
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(agent: "claude", runID: "old", event: "SessionStart"),
            adapter: adapter,
            at: first
        )
        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "intruder", event: "PreToolUse"),
            adapter: adapter,
            at: later
        )
        XCTAssertEqual(state.runID, "old")

        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "new", event: "SessionStart"),
            adapter: adapter,
            at: later
        )
        XCTAssertEqual(state.runID, "new")
        XCTAssertTrue(state.retiredRunIDs.contains("old"))

        let unchanged = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "old", event: "SessionStart"),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(unchanged, state)
    }

    func testSequenceAndSettledTurnRejectLateEventsAndDuplicateStop() {
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(
                agent: "claude", runID: "run", event: "UserPromptSubmit", turnID: "turn", sequence: 1
            ),
            adapter: adapter,
            at: first
        )
        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "run", event: "Stop", turnID: "turn", sequence: 3),
            adapter: adapter,
            at: later
        )
        XCTAssertEqual(state.completionCount, 1)

        for event in [
            HarnessEvent(agent: "claude", runID: "run", event: "PreToolUse", turnID: "turn", sequence: 2),
            HarnessEvent(agent: "claude", runID: "run", event: "PermissionRequest", turnID: "turn", requestID: "late", sequence: 4),
            HarnessEvent(agent: "claude", runID: "run", event: "Stop", turnID: "turn", sequence: 5)
        ] {
            state = HarnessLifecycle.reduce(state, event: event, adapter: adapter, at: Date(timeIntervalSince1970: 30))
        }
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.completionCount, 1)
        XCTAssertEqual(state.since, later)
        XCTAssertTrue(state.blockers.isEmpty)
    }

    func testOverlappingBlockersResolveIndependentlyAndWorkingDoesNotClearThem() {
        var state = PaneLifecycle()
        for event in [
            HarnessEvent(agent: "claude", runID: "run", event: "PermissionRequest", requestID: "one"),
            HarnessEvent(agent: "claude", runID: "run", event: "PermissionRequest", requestID: "two"),
            HarnessEvent(agent: "claude", runID: "run", event: "PostToolUse")
        ] {
            state = HarnessLifecycle.reduce(state, event: event, adapter: adapter, at: first)
        }
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertEqual(Set(state.blockers.keys), ["permission:one", "permission:two"])

        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(agent: "claude", runID: "run", event: "resolved", requestID: "permission:one"),
            adapter: CanonicalHarnessAdapter(id: "claude"),
            at: later
        )
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertEqual(Set(state.blockers.keys), ["permission:two"])
    }

    func testEndRunRetiresAuthorityAndIsIdempotent() {
        let working = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(agent: "claude", runID: "run", event: "PreToolUse"),
            adapter: adapter,
            at: first
        )
        let ended = HarnessLifecycle.endRun(working, at: later)
        XCTAssertFalse(ended.hasAgent)
        XCTAssertTrue(ended.retiredRunIDs.contains("run"))
        XCTAssertEqual(HarnessLifecycle.endRun(ended, at: Date(timeIntervalSince1970: 30)), ended)
    }
}
