import XCTest
@testable import Agents

final class CodexTitleStatusTests: XCTestCase {
    func testEveryWorkingSpinnerFrameClearsAttention() {
        for frame in "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" {
            XCTAssertEqual(CodexTitleStatus.parse("\(frame) secrets"), .clear)
        }
        XCTAssertEqual(CodexTitleStatus.parse("⠋"), .clear)
    }

    func testBothActionRequiredBlinkPhasesStayBlocked() {
        for prefix in ["[ ! ] Action Required", "[ . ] Action Required"] {
            XCTAssertEqual(CodexTitleStatus.parse(prefix), .set(.blocked))
            XCTAssertEqual(CodexTitleStatus.parse("\(prefix) | secrets"), .set(.blocked))
        }
    }

    func testOrdinaryTitlesAndTitleGenerationDoNotChangeAttention() {
        for title in ["", "secrets", "Working", "✳ secrets", "◐ secrets",
                      "renaming... ⠋", "secrets | ⠋", "⠋secrets",
                      "Discuss [ ! ] Action Required", "[ ! ] Action Requiredness"] {
            XCTAssertNil(CodexTitleStatus.parse(title), title)
        }
    }
}
