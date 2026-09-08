import XCTest
@testable import Agents

@MainActor
final class ReviewControllerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testOpenReturnsImmediatelyAndKeepsOverlayAliveWithoutFeedback() throws {
        let overlays = OverlayCenter()
        var delivered: [String] = []
        let controller = makeController(overlays: overlays) { _, message in
            delivered.append(message)
            return nil
        }

        XCTAssertNil(controller.open(request(session: "one")))
        XCTAssertEqual(overlays.reviewSessionIDs, ["one"])
        XCTAssertTrue(delivered.isEmpty)

        let review = try reviewID(in: overlays, session: "one")
        try write("first note", named: "annotations.md", review: review)
        XCTAssertNil(controller.submit(session: "one", review: review))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(overlays.reviewSessionIDs, ["one"])
    }

    func testDifferentSessionsHaveIndependentReviews() throws {
        let overlays = OverlayCenter()
        var origins: [ReviewOrigin] = []
        let controller = makeController(overlays: overlays) { origin, _ in
            origins.append(origin)
            return nil
        }

        XCTAssertNil(controller.open(request(session: "one")))
        XCTAssertNil(controller.open(request(session: "two")))
        let one = try reviewID(in: overlays, session: "one")
        let two = try reviewID(in: overlays, session: "two")
        XCTAssertNotEqual(one, two)

        try write("one note", named: "annotations.md", review: one)
        try write("two note", named: "annotations.md", review: two)
        XCTAssertNil(controller.submit(session: "two", review: two))
        XCTAssertNil(controller.submit(session: "one", review: one))
        XCTAssertEqual(origins.map(\.session), ["two", "one"])
    }

    func testPresentationFailureRemovesOnlyItsOwnDirectory() throws {
        let overlays = OverlayCenter()
        try overlays.present(command: "/tmp/already-open", workingDirectory: "/tmp", sessionID: "one")
        let sentinel = root.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
        let controller = makeController(overlays: overlays) { _, _ in nil }

        XCTAssertNotNil(controller.open(request(session: "one")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep-me"])
    }

    func testWrongReviewIDIsRefusedAndFailedDeliveryCanRetry() throws {
        let overlays = OverlayCenter()
        var attempts = 0
        let controller = makeController(overlays: overlays) { _, _ in
            attempts += 1
            return attempts == 1 ? "pane unavailable" : nil
        }
        XCTAssertNil(controller.open(request(session: "one")))
        let review = try reviewID(in: overlays, session: "one")
        try write("retry this", named: "annotations.md", review: review)

        XCTAssertEqual(controller.submit(session: "one", review: UUID()), "this review is no longer open")
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(controller.submit(session: "one", review: review), "pane unavailable")
        XCTAssertNil(controller.submit(session: "one", review: review))
        XCTAssertEqual(attempts, 2)
    }

    func testFlushThenCleanQuitDoesNotDeliverAnnotationsTwiceAndCleansUp() throws {
        let overlays = OverlayCenter()
        var delivered: [String] = []
        let controller = makeController(overlays: overlays) { _, message in
            delivered.append(message)
            return nil
        }
        XCTAssertNil(controller.open(request(session: "one")))
        let review = try reviewID(in: overlays, session: "one")
        try write("same note", named: "annotations.md", review: review)
        try write("10\n", named: "status", review: review)

        XCTAssertNil(controller.submit(session: "one", review: review))
        controller.closed(session: "one", outcome: .finished)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(
            delivered.last,
            "The RevDiff overlay is now closed. Its annotations were already submitted; do not apply them again. Reopen the cumulative review after any pending feedback changes are verified."
        )
        XCTAssertEqual(delivered.filter { $0.contains("same note") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(for: review).path))
    }

    func testOriginEndingCancelsOnlyItsReviewAndCleansItsDirectory() throws {
        let overlays = OverlayCenter()
        let controller = makeController(overlays: overlays) { _, _ in nil }
        overlays.onClosed = { session, outcome in controller.closed(session: session, outcome: outcome) }
        let firstRequest = request(session: "one")
        let secondRequest = request(session: "two")
        XCTAssertNil(controller.open(firstRequest))
        XCTAssertNil(controller.open(secondRequest))
        let first = try reviewID(in: overlays, session: "one")
        let second = try reviewID(in: overlays, session: "two")

        controller.originEnded(ReviewOrigin(
            session: "one", pane: firstRequest.pane, agent: "codex", agentSessionID: "wrong"
        ))
        XCTAssertEqual(overlays.reviewSessionIDs, ["one", "two"])

        controller.originEnded(ReviewOrigin(
            session: "one", pane: firstRequest.pane, agent: "codex", agentSessionID: "agent-one"
        ))
        XCTAssertEqual(overlays.reviewSessionIDs, ["two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory(for: second).path))
    }

    func testShutdownCancelsEveryOverlayAndCleansEveryDirectory() throws {
        let overlays = OverlayCenter()
        let controller = makeController(overlays: overlays) { _, _ in nil }
        overlays.onClosed = { session, outcome in controller.closed(session: session, outcome: outcome) }
        XCTAssertNil(controller.open(request(session: "one")))
        XCTAssertNil(controller.open(request(session: "two")))
        let directories = try ["one", "two"].map {
            directory(for: try reviewID(in: overlays, session: $0))
        }

        controller.shutdown()

        XCTAssertTrue(overlays.reviewSessionIDs.isEmpty)
        XCTAssertTrue(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFinishedExitAndCancellationCleanTheirOwnDirectories() throws {
        let overlays = OverlayCenter()
        var delivered: [String] = []
        let controller = makeController(overlays: overlays) { _, message in
            delivered.append(message)
            return nil
        }
        XCTAssertNil(controller.open(request(session: "finished")))
        let finished = try reviewID(in: overlays, session: "finished")
        try write("2\n", named: "status", review: finished)
        try write("review tool failed\n", named: "stderr", review: finished)
        controller.closed(session: "finished", outcome: .finished)

        XCTAssertEqual(delivered, [
            "RevDiff exited with status 2. The review was not completed.\nreview tool failed"
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(for: finished).path))

        XCTAssertNil(controller.open(request(session: "cancelled")))
        let cancelled = try reviewID(in: overlays, session: "cancelled")
        controller.closed(session: "cancelled", outcome: .cancelled)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(for: cancelled).path))
    }

    private func makeController(
        overlays: OverlayCenter,
        deliver: @escaping (ReviewOrigin, String) -> String?
    ) -> ReviewController {
        ReviewController(
            overlays: overlays,
            socketPath: "/tmp/agents.sock",
            runnerURL: URL(fileURLWithPath: "/tmp/review-run.sh"),
            temporaryDirectory: root,
            origin: { session, pane in
                ReviewOrigin(session: session, pane: pane, agent: "codex", agentSessionID: "agent-\(session)")
            },
            deliver: deliver
        )
    }

    private func request(session: String) -> ReviewRequest {
        ReviewRequest(
            session: session, pane: UUID(), command: "/tmp/revdiff", arguments: [],
            workingDirectory: "/tmp", environment: [:]
        )
    }

    private func reviewID(in overlays: OverlayCenter, session: String) throws -> UUID {
        let value = try XCTUnwrap(overlays.view(forSession: session)?.configuration.envVars["AGENTS_REVIEW_ID"])
        return try XCTUnwrap(UUID(uuidString: value))
    }

    private func directory(for review: UUID) -> URL {
        root.appendingPathComponent("agents-review-\(review.uuidString)")
    }

    private func write(_ value: String, named name: String, review: UUID) throws {
        try value.write(to: directory(for: review).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
