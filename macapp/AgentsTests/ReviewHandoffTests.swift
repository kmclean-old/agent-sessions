import XCTest
@testable import Agents

final class ReviewHandoffTests: XCTestCase {
    func testSubmitSuppressesEmptyAndDuplicateAnnotations() {
        var handoff = ReviewHandoff()

        XCTAssertNil(handoff.message(for: .submitted(" \n\t ")))
        let message = handoff.message(for: .submitted("  fix the race\u{0}  "))
        XCTAssertEqual(
            message,
            "RevDiff feedback submitted. Address these annotations. The review is still open; let it reload instead of opening another overlay.\n\nfix the race"
        )

        handoff.didSubmit("  fix the race\u{0}  ")
        XCTAssertNil(handoff.message(for: .submitted("fix the race")))
    }

    func testFailedDeliveryCanRetryTheSameSubmission() {
        var handoff = ReviewHandoff()
        let first = handoff.message(for: .submitted("retry me"))

        XCTAssertNotNil(first)
        XCTAssertEqual(handoff.message(for: .submitted("retry me")), first)

        handoff.didSubmit("retry me")
        XCTAssertNil(handoff.message(for: .submitted("retry me")))
    }

    func testCleanExitReportsCompletionAndSuppressesFlushedAnnotations() {
        var handoff = ReviewHandoff()

        XCTAssertEqual(
            handoff.message(for: .exited(status: 0, annotations: "", error: "")),
            "The user finished the RevDiff review without annotations. This review is complete."
        )

        handoff.didSubmit("already delivered")
        XCTAssertEqual(
            handoff.message(for: .exited(
                status: 10, annotations: "already delivered", error: ""
            )),
            "The RevDiff overlay is now closed. Its annotations were already submitted; do not apply them again. Reopen the cumulative review after any pending feedback changes are verified."
        )
    }

    func testExitErrorsAreReportedWhileSignalsAndCancellationStaySilent() {
        let handoff = ReviewHandoff()

        XCTAssertEqual(
            handoff.message(for: .exited(status: 2, annotations: "ignored", error: " bad\u{0} news \n")),
            "RevDiff exited with status 2. The review was not completed.\nbad news"
        )
        XCTAssertNil(handoff.message(for: .exited(status: nil, annotations: "", error: "")))
        for status in [129, 130, 137, 143] {
            XCTAssertNil(handoff.message(for: .exited(status: status, annotations: "", error: "")))
        }
        XCTAssertNil(handoff.message(for: .cancelled))
    }
}
