import AppKit
import XCTest
@testable import Agents

@MainActor
final class PaneHostContainerViewTests: XCTestCase {
    private final class TestSurfaceView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testSwitchingSessionsKeepsMountedViewsAndUpdatesVisibility() {
        let container = PaneHostContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let firstID = UUID()
        let secondID = UUID()
        let firstView = TestSurfaceView()
        let secondView = TestSurfaceView()
        container.mount(firstView)
        container.mount(secondView)

        container.present(
            panes: [paneItem(id: firstID, view: firstView)],
            dividers: [],
            context: "first"
        )

        XCTAssertTrue(firstView.superview === container)
        XCTAssertTrue(secondView.superview === container)
        XCTAssertFalse(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)

        container.present(
            panes: [paneItem(id: secondID, view: secondView)],
            dividers: [],
            context: "second"
        )

        XCTAssertTrue(firstView.superview === container)
        XCTAssertTrue(secondView.superview === container)
        XCTAssertTrue(firstView.isHidden)
        XCTAssertFalse(secondView.isHidden)

        container.present(
            panes: [paneItem(id: firstID, view: firstView)],
            dividers: [],
            context: "first"
        )

        XCTAssertTrue(firstView.superview === container)
        XCTAssertTrue(secondView.superview === container)
        XCTAssertFalse(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)
    }

    func testSplitLayoutAndFocusSurviveEmptyPresentationAndReselection() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = PaneHostContainerView(frame: window.contentView!.bounds)
        window.contentView = container
        let leftID = UUID()
        let rightID = UUID()
        let leftView = TestSurfaceView()
        let rightView = TestSurfaceView()
        container.mount(leftView)
        container.mount(rightView)

        let panes = [
            paneItem(
                id: leftID,
                view: leftView,
                unitFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                isFocused: false
            ),
            paneItem(
                id: rightID,
                view: rightView,
                unitFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                isFocused: true
            ),
        ]
        let dividers = [
            PaneHostContainerView.DividerItem(
                path: [],
                axis: .horizontal,
                unitRegion: CGRect(x: 0, y: 0, width: 1, height: 1),
                ratio: 0.5,
                generation: 0
            ),
        ]

        container.present(panes: panes, dividers: dividers, context: "session")
        container.layoutSubtreeIfNeeded()
        assertSplitFrames(leftView: leftView, rightView: rightView, in: container)
        XCTAssertTrue(window.firstResponder === rightView)

        container.presentNothing()
        XCTAssertTrue(leftView.isHidden)
        XCTAssertTrue(rightView.isHidden)

        container.present(panes: panes, dividers: dividers, context: "session")
        container.layoutSubtreeIfNeeded()

        assertSplitFrames(leftView: leftView, rightView: rightView, in: container)
        XCTAssertFalse(leftView.isHidden)
        XCTAssertFalse(rightView.isHidden)
        XCTAssertTrue(window.firstResponder === rightView)
    }

    private func paneItem(
        id: UUID,
        view: NSView,
        unitFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        isFocused: Bool = true
    ) -> PaneHostContainerView.PaneItem {
        PaneHostContainerView.PaneItem(
            paneID: id,
            view: view,
            unitFrame: unitFrame,
            isFocused: isFocused
        )
    }

    private func assertSplitFrames(
        leftView: NSView,
        rightView: NSView,
        in container: PaneHostContainerView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let midpoint = container.bounds.midX
        XCTAssertEqual(
            leftView.frame,
            CGRect(x: 0, y: 0, width: midpoint, height: container.bounds.height),
            file: file,
            line: line
        )
        XCTAssertEqual(
            rightView.frame,
            CGRect(x: midpoint, y: 0, width: midpoint, height: container.bounds.height),
            file: file,
            line: line
        )
    }
}
