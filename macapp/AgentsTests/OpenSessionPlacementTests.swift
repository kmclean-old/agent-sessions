import XCTest
@testable import Agents

/// `OpenSessionPlacement.resolve` with the disk taken out: paths are
/// compared as written and the repository root is whatever the test says,
/// so each case pins the rule and nothing else. `AppStoreOpenSessionTests`
/// covers the same rule against real directories.
final class OpenSessionPlacementTests: XCTestCase {
    private func resolve(
        _ directory: String,
        projects: [String] = [],
        workspaces: [WorkspaceRow] = [],
        hidden: [ArchivedProject] = [],
        repositoryRoot: String? = nil
    ) -> OpenSessionPlacement {
        OpenSessionPlacement.resolve(
            directory: directory,
            projects: projects.map { Project(path: $0) },
            workspaces: workspaces,
            hidden: hidden,
            canonicalPath: { $0 },
            repositoryRoot: { _ in repositoryRoot }
        )
    }

    func testAProjectContainsItsOwnDirectoryAndEverythingBelowIt() {
        XCTAssertEqual(resolve("/code/app", projects: ["/code/app"]), .target(.root(projectPath: "/code/app")))
        XCTAssertEqual(resolve("/code/app/src/lib", projects: ["/code/app"]), .target(.root(projectPath: "/code/app")))
    }

    func testContainmentIsByWholePathComponents() {
        XCTAssertEqual(
            resolve("/code/application", projects: ["/code/app"], repositoryRoot: "/code/application"),
            .newProject(path: "/code/application"),
            "/code/app is not an ancestor of /code/application, however the strings line up"
        )
        XCTAssertTrue(OpenSessionPlacement.contains("/", "/code"))
        XCTAssertTrue(OpenSessionPlacement.contains("/code/app/", "/code/app/src"))
        XCTAssertFalse(OpenSessionPlacement.contains("/code/app/src", "/code/app"))
    }

    func testTheDeepestContainingProjectWins() {
        let projects = ["/code/monorepo", "/code/monorepo/packages/web", "/code/other"]
        XCTAssertEqual(
            resolve("/code/monorepo/packages/web/src", projects: projects),
            .target(.root(projectPath: "/code/monorepo/packages/web"))
        )
        XCTAssertEqual(
            resolve("/code/monorepo/packages/api", projects: projects),
            .target(.root(projectPath: "/code/monorepo"))
        )
    }

    func testAWorkspaceContainsItsOwnDirectory() {
        let workspace = WorkspaceRow(
            projectPath: "/code/app", name: "quiet-otter", path: "/code/.workspaces/app/quiet-otter", label: nil
        )
        XCTAssertEqual(
            resolve("/code/.workspaces/app/quiet-otter/src", projects: ["/code/app"], workspaces: [workspace]),
            .target(.workspace(projectPath: "/code/app", name: "quiet-otter"))
        )
    }

    func testAHiddenProjectOrItsWorkspaceIsFoundAndMarkedHidden() {
        let workspace = WorkspaceRow(
            projectPath: "/code/parked", name: "ws", path: "/code/.workspaces/parked/ws", label: nil
        )
        let parked = ArchivedProject(path: "/code/parked", archivedAt: Date(), sessions: [], workspaces: [workspace])
        XCTAssertEqual(
            resolve("/code/parked/src", projects: ["/code"], hidden: [parked]),
            .hiddenTarget(.root(projectPath: "/code/parked")),
            "the hidden project is deeper than the live one around it, so it is where the session belongs"
        )
        XCTAssertEqual(
            resolve("/code/.workspaces/parked/ws", hidden: [parked]),
            .hiddenTarget(.workspace(projectPath: "/code/parked", name: "ws"))
        )
    }

    func testAnUncontainedDirectoryBecomesAProjectAtItsRepositoryRootOrItself() {
        XCTAssertEqual(
            resolve("/code/new/src", projects: ["/code/app"], repositoryRoot: "/code/new"),
            .newProject(path: "/code/new")
        )
        XCTAssertEqual(
            resolve("/Users/kira/scratch", projects: ["/code/app"], repositoryRoot: nil),
            .newProject(path: "/Users/kira/scratch")
        )
    }

    /// The default canonicalization resolves links on both sides, so a
    /// project registered under one spelling of a directory contains a
    /// request naming it by another — here macOS's own `/tmp`, which is
    /// `/private/tmp`.
    func testCanonicalPathResolvesLinksSoBothSpellingsMeet() {
        XCTAssertEqual(OpenSessionPlacement.canonicalPath("/tmp/"), OpenSessionPlacement.canonicalPath("/private/tmp"))
        XCTAssertEqual(
            OpenSessionPlacement.canonicalPath("/no/such/dir/../place/"), "/no/such/place",
            "a path that doesn't exist is compared as written, standardized"
        )
    }
}
