import Foundation
import XCTest
@testable import Agents

@MainActor
final class HarnessSetupEvidenceTests: XCTestCase {
    func testAcceptedReportsUpdateEvidenceForEachHarnessAcrossPanes() {
        let (store, terminals, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/setup-evidence-project")
        let session = store.sessions[0].id
        let first = Date(timeIntervalSince1970: 10)
        let second = Date(timeIntervalSince1970: 20)
        store.now = { first }
        XCTAssertTrue(store.observedHarnessReports.isEmpty)

        let claude = HarnessEvent(agent: "claude", runID: "claude-run", event: "SessionStart")
        XCTAssertNotNil(terminals.onHarnessEvent?(session, UUID(), claude))
        XCTAssertEqual(store.observedHarnessReports, ["claude": first])

        store.now = { second }
        let codex = HarnessEvent(agent: "codex", runID: "codex-run", event: "SessionStart")
        XCTAssertNotNil(terminals.onHarnessEvent?(session, UUID(), codex))
        XCTAssertEqual(store.observedHarnessReports, ["claude": first, "codex": second])
    }

    func testRejectedReportsDoNotCreateOrRefreshEvidence() {
        let (store, terminals, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/setup-evidence-project")
        let session = store.sessions[0].id
        let pane = UUID()
        let first = Date(timeIntervalSince1970: 10)
        store.now = { first }
        let event = HarnessEvent(agent: "claude", runID: "run", event: "SessionStart", sequence: 2)

        XCTAssertNil(terminals.onHarnessEvent?("unknown-session", pane, event))
        XCTAssertTrue(store.observedHarnessReports.isEmpty)
        XCTAssertNotNil(terminals.onHarnessEvent?(session, pane, event))

        store.now = { Date(timeIntervalSince1970: 20) }
        XCTAssertNil(terminals.onHarnessEvent?(session, pane, event), "Duplicate sequence is refused")
        let otherRun = HarnessEvent(agent: "claude", runID: "other", event: "PreToolUse")
        XCTAssertNil(terminals.onHarnessEvent?(session, pane, otherRun))
        terminals.onHarnessEnded?(session, pane)
        let retiredRun = HarnessEvent(agent: "claude", runID: "run", event: "SessionStart", sequence: 3)
        XCTAssertNil(terminals.onHarnessEvent?(session, pane, retiredRun))
        XCTAssertEqual(store.observedHarnessReports, ["claude": first])
    }

    func testTitleSignalsAndRunEndDoNotChangeLastReportTime() {
        let (store, terminals, _) = TestSupport.makeStore()
        store.addProject(path: "/tmp/setup-evidence-project")
        let session = store.sessions[0].id
        let pane = UUID()
        terminals.onSessionSignal?(session, pane, .structured(.clear))
        XCTAssertTrue(store.observedHarnessReports.isEmpty)

        let first = Date(timeIntervalSince1970: 10)
        store.now = { first }
        let event = HarnessEvent(agent: "codex", runID: "run", event: "SessionStart")
        XCTAssertNotNil(terminals.onHarnessEvent?(session, pane, event))
        store.now = { Date(timeIntervalSince1970: 50_000) }
        _ = store.applyHarnessTitle("[ ! ] Action Required", toSession: session, pane: pane)
        terminals.onHarnessEnded?(session, pane)
        terminals.onPaneClosed?(session, pane)
        XCTAssertEqual(store.observedHarnessReports, ["codex": first])
    }

    func testEvidenceIsNeverRestoredFromSavedSessionState() {
        let (store, terminals, stateURL) = TestSupport.makeStore()
        store.addProject(path: "/tmp/setup-evidence-project")
        let session = store.sessions[0].id
        let event = HarnessEvent(agent: "claude", runID: "run", event: "SessionStart")
        XCTAssertNotNil(terminals.onHarnessEvent?(session, UUID(), event))
        store.renameSession(session, to: "Saved session")

        let restored = AppStore(terminals: SpyTerminals(), stateURL: stateURL, engine: FakeWorkspaceEngine())
        XCTAssertFalse(restored.sessions.isEmpty)
        XCTAssertTrue(restored.observedHarnessReports.isEmpty)
    }
}
