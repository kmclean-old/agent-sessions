import GhosttyTerminal
import XCTest
@testable import Agents

@MainActor
final class ReviewDeliveryTests: XCTestCase {
    func testDeliveryReturnsToOriginatingPaneAfterFocusChanges() throws {
        var deliveries: [(TerminalView, String)] = []
        let center = TerminalCenter(promptDelivery: { view, message in
            deliveries.append((view, message))
            return true
        })
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let originPane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        let originView = try XCTUnwrap(center.view(forPane: originPane))
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: originPane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: originPane))
        _ = center.splitPane(in: "session", axis: .horizontal, workingDirectory: "/tmp")

        XCTAssertNil(center.deliverReview(to: origin, message: "feedback"))
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertIdentical(deliveries[0].0, originView)
        XCTAssertEqual(deliveries[0].1, "feedback")
    }

    func testDeliveryRefusesClosedOrReplacedAgentAndSessionEnd() throws {
        var deliveryCount = 0
        let center = TerminalCenter(promptDelivery: { _, _ in deliveryCount += 1; return true })
        var exits: [ReviewOrigin] = []
        center.onAgentExit = { exits.append($0) }
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let original = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))

        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "claude", name: "SessionStart", sessionID: "agent-2", query: nil)
        )
        XCTAssertNotNil(center.deliverReview(to: original, message: "stale"))

        let replacement = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "claude", name: "SessionEnd", sessionID: "agent-2", query: nil)
        )
        XCTAssertEqual(exits, [original, replacement])
        XCTAssertNotNil(center.deliverReview(to: replacement, message: "ended"))
        center.closeSession("session")
        XCTAssertNotNil(center.deliverReview(to: replacement, message: "closed"))
        XCTAssertEqual(deliveryCount, 0)
    }

    func testOriginAndDeliveryRefuseAQuiescedPane() async throws {
        let center = TerminalCenter(promptDelivery: { _, _ in true })
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))

        await center.quiesceSessions(["session"])

        XCTAssertNil(center.reviewOrigin(session: "session", pane: pane))
        XCTAssertNotNil(center.deliverReview(to: origin, message: "stale"))
    }

    func testCommandFinishedClearsTheOriginBeforeTheShellCanReceiveFeedback() throws {
        var deliveryCount = 0
        let center = TerminalCenter(promptDelivery: { _, _ in deliveryCount += 1; return true })
        var exits: [ReviewOrigin] = []
        center.onAgentExit = { exits.append($0) }
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))

        center.handleCommandFinished(paneID: pane)

        XCTAssertNil(center.reviewOrigin(session: "session", pane: pane))
        XCTAssertNotNil(center.deliverReview(to: origin, message: "must not reach the shell"))
        XCTAssertEqual(deliveryCount, 0)
        XCTAssertEqual(exits, [origin])
    }

    func testClosingTheOriginPaneEmitsItsIdentityAndKeepsTheSiblingSession() throws {
        let center = TerminalCenter()
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let originPane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: originPane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: originPane))
        let sibling = try XCTUnwrap(
            center.splitPane(in: "session", axis: .horizontal, workingDirectory: "/tmp")
        )
        center.focusPane(originPane)
        var exits: [ReviewOrigin] = []
        center.onAgentExit = { exits.append($0) }

        XCTAssertTrue(center.closeFocusedPane(in: "session"))

        XCTAssertEqual(exits, [origin])
        XCTAssertNil(center.view(forPane: originPane))
        XCTAssertNotNil(center.view(forPane: sibling))
        XCTAssertEqual(center.layouts["session"]?.paneCount, 1)
    }

    func testUnknownLiveAgentCanRequestAndReceiveReview() throws {
        var delivered = false
        let center = TerminalCenter(promptDelivery: { _, _ in delivered = true; return true })
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "custom-agent", name: "SessionStart", sessionID: "custom-1", query: nil)
        )

        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))
        XCTAssertEqual(origin.agent, "custom-agent")
        XCTAssertNil(center.deliverReview(to: origin, message: "feedback"))
        XCTAssertTrue(delivered)
    }

    func testDeliveryReportsPromptRefusal() throws {
        let center = TerminalCenter(promptDelivery: { _, _ in false })
        _ = center.terminalView(for: "session", workingDirectory: "/tmp", restoredResume: nil)
        let pane = try XCTUnwrap(center.layouts["session"]?.initialPane)
        center.handleAgentSessionEvent(
            sessionID: "session", paneID: pane,
            event: AgentSessionEvent(agent: "codex", name: "SessionStart", sessionID: "agent-1", query: nil)
        )
        let origin = try XCTUnwrap(center.reviewOrigin(session: "session", pane: pane))

        XCTAssertEqual(
            center.deliverReview(to: origin, message: "feedback"),
            "the requesting pane cannot accept input"
        )
    }
}
