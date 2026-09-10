import Foundation
import XCTest
@testable import Agents

@MainActor
final class HarnessIntegrationTests: XCTestCase {
    private func fixture() -> (AppStore, SpyTerminals, String, UUID) {
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/lifecycle-project")
        store.setAppActive(false)
        return (store, spy, store.sessions[0].id, UUID())
    }

    private func event(_ name: String, run: String = "run-1", request: String? = nil) -> HarnessEvent {
        HarnessEvent(agent: "custom-test", runID: run, conversationID: "conversation-1",
                     event: name, requestID: request)
    }

    func testEverySessionHasAnUnknownSummaryBeforeAnyHarnessReports() {
        let (store, _, id, _) = fixture()
        XCTAssertEqual(store.sessionStates[id]?.phase, .unknown)
        XCTAssertTrue(AgentDashboard.entries(sessions: store.sessions, states: store.sessionStates).isEmpty)
    }

    func testCallbacksDriveCompletionAndFocusAcknowledgesItOutsideTheDashboard() {
        let (store, spy, id, pane) = fixture()
        XCTAssertNotNil(spy.onHarnessEvent?(id, pane, event("registered")))
        XCTAssertEqual(store.sessionStates[id]?.phase, .idle)
        XCTAssertNil(store.attention[id]?.activity)
        _ = spy.onHarnessEvent?(id, pane, event("working"))
        XCTAssertEqual(store.sessionStates[id]?.phase, .working)
        _ = spy.onHarnessEvent?(id, pane, event("settled"))
        let snapshot = store.sessionStates
        let before = store.paneLifecycle
        let rows = AgentDashboard.entries(sessions: store.sessions, states: snapshot)
        XCTAssertEqual(rows.first?.paneID, pane)
        XCTAssertEqual(rows.first?.reason, "Done · ready to review")
        XCTAssertEqual(store.paneLifecycle, before, "Reading the dashboard must have no lifecycle side effects")
        store.setAppActive(true)
        XCTAssertNil(store.attention[id]?.activity)
        XCTAssertEqual(store.sessionStates[id]?.phase, .idle)
        XCTAssertEqual(snapshot[id]?.readyCount, 1, "Previously published snapshots remain values")
    }

    func testWorkingSiblingDoesNotHideCompletionOrClearAnotherPanesBlock() {
        let (store, spy, id, first) = fixture()
        let second = UUID()
        for pane in [first, second] {
            _ = spy.onHarnessEvent?(id, pane, event("registered"))
            _ = spy.onHarnessEvent?(id, pane, event("working"))
        }
        _ = spy.onHarnessEvent?(id, first, event("settled"))
        XCTAssertEqual(store.sessionStates[id]?.phase, .working)
        XCTAssertEqual(store.sessionStates[id]?.readyCount, 1)
        XCTAssertEqual(store.sessionStates[id]?.attentionPane, first)
        _ = spy.onHarnessEvent?(id, second, event("blocked", request: "approval"))
        XCTAssertEqual(store.sessionStates[id]?.attentionPane, second)
        XCTAssertEqual(store.blockedSessionCount, 1)
        store.setAppActive(true)
        XCTAssertEqual(store.attention[id]?.activity, .blocked)
        _ = spy.onHarnessEvent?(id, first, event("working"))
        XCTAssertEqual(store.attention[id]?.activity, .blocked)
        spy.onPaneClosed?(id, second)
        XCTAssertEqual(store.blockedSessionCount, 0)
        XCTAssertEqual(store.sessionStates[id]?.phase, .working)
    }

    func testRunEndReleasesAuthorityAndRetiredEventsCannotClaimItAgain() {
        let (store, spy, id, pane) = fixture()
        _ = spy.onHarnessEvent?(id, pane, event("registered"))
        _ = spy.onHarnessEvent?(id, pane, event("blocked"))
        spy.onSessionSignal?(id, pane, .structured(.clear))
        XCTAssertEqual(store.attention[id]?.activity, .blocked)
        spy.onHarnessEnded?(id, pane)
        XCTAssertNil(store.attention[id]?.activity)
        XCTAssertEqual(store.sessionStates[id]?.phase, .unknown)
        XCTAssertNil(spy.onHarnessEvent?(id, pane, event("registered")))
        _ = spy.onHarnessEvent?(id, pane, event("registered", run: "replacement"))
        XCTAssertEqual(store.sessionStates[id]?.phase, .idle)
        spy.onPaneClosed?(id, pane)
        XCTAssertNil(store.paneLifecycle[id]?[pane])
    }

    func testLifecycleIsNeverRestoredFromSavedSessionMetadata() {
        let (store, spy, stateURL) = TestSupport.makeStore()
        store.addProject(path: "/tmp/lifecycle-project")
        let id = store.sessions[0].id
        let pane = UUID()
        _ = spy.onHarnessEvent?(id, pane, event("registered"))
        _ = spy.onHarnessEvent?(id, pane, event("blocked"))
        // Renaming forces a save while the harness is blocked.
        store.renameSession(id, to: "A resumable row")
        let restored = AppStore(terminals: SpyTerminals(), stateURL: stateURL, engine: FakeWorkspaceEngine())
        XCTAssertEqual(restored.sessionStates[id]?.phase, .unknown)
        XCTAssertTrue(restored.paneLifecycle.isEmpty)
    }

    func testControlEventValidatesGenerationBeforeTouchingStateOrResumeMetadata() async throws {
        let center = TerminalCenter()
        let store = AppStore(terminals: center, stateURL: TestSupport.freshStateURL(), engine: FakeWorkspaceEngine())
        store.addProject(path: "/tmp/lifecycle-control")
        let id = store.sessions[0].id
        center.ensureSession(id, workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts[id]?.initialPane)
        let generation = try XCTUnwrap(center.paneGeneration(pane))
        func report(_ generation: UUID, session: String? = nil) -> ControlHarnessEvent {
            ControlHarnessEvent(session: session ?? id, pane: pane, generation: generation,
                                event: event("registered"), prompt: "Inspect lifecycle", home: nil)
        }
        XCTAssertNotNil(center.handleControlHarnessEvent(report(UUID())))
        XCTAssertNotNil(center.handleControlHarnessEvent(report(generation, session: "wrong-row")))
        XCTAssertTrue(store.paneLifecycle.isEmpty)
        XCTAssertNil(center.handleControlHarnessEvent(report(generation)))
        XCTAssertEqual(store.sessionStates[id]?.phase, .idle)
        XCTAssertEqual(store.sessions[0].resume?.sessionID, "conversation-1")
        await center.quiesceSessions([id])
        center.resumeSessions([id])
        center.ensureSession(id, workingDirectory: "/tmp", restoredResume: nil)
        XCTAssertNotEqual(center.paneGeneration(pane), generation)
        XCTAssertNotNil(center.handleControlHarnessEvent(report(generation)))
        XCTAssertEqual(store.sessionStates[id]?.phase, .unknown)
        center.closeSession(id)
    }

    func testVersionedWireCarriesNativeEventAndRejectsMalformedIdentity() throws {
        let pane = UUID()
        let generation = UUID()
        var payload: [String: Any] = [
            "cmd": "harness-event", "version": 1, "session": "app-session", "pane": pane.uuidString,
            "generation": generation.uuidString, "agent": "codex", "run_id": "process-instance",
            "event": "PermissionRequest", "pid": 1234, "turn_id": "turn", "request_id": "tool",
            "agent_session_id": "conversation", "sequence": 8
        ]
        func decode() throws -> ControlServer.RequestDecision {
            ControlServer.decide(line: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        }
        guard case .harnessEvent(let report) = try decode() else { return XCTFail("Expected harness report") }
        XCTAssertEqual(report.generation, generation)
        XCTAssertEqual(report.event.requestID, "tool")
        XCTAssertEqual(report.event.sequence, 8)
        payload["version"] = 99
        guard case .refuse = try decode() else { return XCTFail("Unknown version accepted") }
        payload["version"] = 1
        payload["generation"] = nil
        guard case .refuse = try decode() else { return XCTFail("Missing generation accepted") }
    }

    func testKernelExitObservationDoesNotNeedATimerOrPolling() async throws {
        let exited = expectation(description: "Registered process exited")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        var observation: HarnessProcessObservation? = HarnessProcessObservation(pid: process.processIdentifier) {
            exited.fulfill()
        }
        process.terminate()
        await fulfillment(of: [exited], timeout: 3)
        observation = nil
        _ = observation
    }
}
