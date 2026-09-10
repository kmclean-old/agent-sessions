import XCTest
@testable import Agents

final class HarnessAdapterTests: XCTestCase {
    func testRegistryUsesCanonicalFallbackForCustomAgent() {
        let adapter = HarnessAdapterRegistry().adapter(for: "Custom")
        XCTAssertEqual(adapter.id, "custom")
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(agent: "custom", runID: "r", event: "blocked", requestID: "q")),
            .blocked(id: "q", reason: nil)
        )
    }

    func testClaudeNotificationsDistinguishPermissionFromIdlePrompt() {
        let adapter = ClaudeHarnessAdapter()
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(
                agent: "claude", runID: "r", event: "Notification", notificationType: "permission_prompt"
            )),
            .blocked(id: "permission", reason: nil)
        )
        XCTAssertNil(adapter.transition(for: HarnessEvent(
            agent: "claude", runID: "r", event: "Notification", notificationType: "idle_prompt"
        )))
    }

    func testIdentifiedPermissionDoesNotGainDuplicateGenericNotificationBlocker() {
        let adapter = ClaudeHarnessAdapter()
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(
                agent: "claude", runID: "r", event: "PermissionRequest", requestID: "request-1"
            ),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 1)
        )
        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(
                agent: "claude", runID: "r", event: "Notification", notificationType: "permission_prompt"
            ),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(Set(state.blockers.keys), ["permission:request-1"])
    }

    func testContinuingStopAndInterruptedToolFailureDoNotComplete() {
        let adapter = ClaudeHarnessAdapter()
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(
                agent: "claude", runID: "r", event: "Stop", willContinue: true
            )),
            .working
        )
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(
                agent: "claude", runID: "r", event: "PostToolUseFailure", isInterrupt: true
            )),
            .settled(outcome: .interrupted)
        )
    }

    func testCodexTitleOnlyResolvesItsOwnGenericBlocker() {
        let adapter = CodexHarnessAdapter()
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(
                agent: "codex", runID: "r", event: "PermissionRequest", requestID: "specific"
            ),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 1)
        )
        state = HarnessLifecycle.observeTitle(
            state, title: "[ ! ] Action Required | task", adapter: adapter,
            at: Date(timeIntervalSince1970: 2)
        )
        state = HarnessLifecycle.observeTitle(
            state, title: "⠋ task", adapter: adapter,
            at: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertEqual(Set(state.blockers.keys), ["permission:specific"])
    }

    func testUnsupportedTitlesLeaveStateUnchanged() {
        let state = PaneLifecycle(agent: "claude", runID: "r", phase: .working)
        XCTAssertEqual(
            HarnessLifecycle.observeTitle(
                state, title: "ordinary title", adapter: ClaudeHarnessAdapter(), at: Date()
            ),
            state
        )
    }

    func testOMPAgentEndHonorsContinuationAndOutcome() {
        let adapter = OMPHarnessAdapter()
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(agent: "omp", runID: "r", event: "agent_end", willContinue: true)),
            .working
        )
        XCTAssertEqual(
            adapter.transition(for: HarnessEvent(
                agent: "omp", runID: "r", event: "agent_end", outcome: "failed"
            )),
            .settled(outcome: .failed)
        )
    }

    func testCompactSessionStartDoesNotResetBusyRun() {
        let adapter = CodexHarnessAdapter()
        var state = HarnessLifecycle.reduce(
            PaneLifecycle(),
            event: HarnessEvent(
                agent: "codex", runID: "r", conversationID: "before", event: "PreToolUse"
            ),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 1)
        )
        state = HarnessLifecycle.reduce(
            state,
            event: HarnessEvent(
                agent: "codex", runID: "r", conversationID: "after", event: "SessionStart", source: "compact"
            ),
            adapter: adapter,
            at: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(state.phase, .working)
        XCTAssertEqual(state.conversationID, "before")
    }
}
