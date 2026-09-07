import XCTest
@testable import Agents

final class WorkspacesRootTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("WorkspacesRootTests-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Resolved once, so expectations can be spelled against the same
        // physical path the code under test resolves to (macOS temp dirs
        // sit behind a symlink).
        base = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func path(_ relativePath: String) -> String {
        base.appendingPathComponent(relativePath).path
    }

    // MARK: - directory(forProject:)

    func test_directory_isASiblingOfTheProjectUnderDotWorkspaces() throws {
        let project = try makeDirectory("code/agents")

        XCTAssertEqual(WorkspacesRoot.directory(forProject: project.path), path("code/.workspaces/agents"))
    }

    func test_directory_keepsSameNamedProjectsInDifferentParentsApart() throws {
        let one = try makeDirectory("code/website")
        let two = try makeDirectory("scratch/website")

        XCTAssertEqual(WorkspacesRoot.directory(forProject: one.path), path("code/.workspaces/website"))
        XCTAssertEqual(WorkspacesRoot.directory(forProject: two.path), path("scratch/.workspaces/website"))
    }

    func test_directory_ignoresTrailingSlashAndDotSegments() throws {
        let project = try makeDirectory("code/agents")
        _ = try makeDirectory("code/other")
        let plain = WorkspacesRoot.directory(forProject: project.path)

        XCTAssertEqual(WorkspacesRoot.directory(forProject: project.path + "/"), plain)
        XCTAssertEqual(WorkspacesRoot.directory(forProject: path("code/other/../agents")), plain)
        XCTAssertEqual(WorkspacesRoot.directory(forProject: path("code/./agents")), plain)
    }

    /// A project reached through a symlink is placed by where it actually
    /// is, not by where the link lives: a shell spawned into it lands at the
    /// physical path, and that is the ancestry its tools walk.
    func test_directory_resolvesSymlinksBeforeTakingTheParent() throws {
        let real = try makeDirectory("code/real-project")
        _ = try makeDirectory("elsewhere")
        let link = base.appendingPathComponent("elsewhere/linked-project")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(WorkspacesRoot.directory(forProject: link.path), path("code/.workspaces/real-project"))
        XCTAssertEqual(
            WorkspacesRoot.directory(forProject: link.path),
            WorkspacesRoot.directory(forProject: real.path)
        )
    }

    /// The repository probe must start at the parent: every project is a
    /// repository, and probing the project itself would send all of them to
    /// the fallback.
    func test_directory_ignoresTheProjectsOwnRepository() throws {
        let project = try makeDirectory("code/agents")
        _ = try makeDirectory("code/agents/.jj")
        _ = try makeDirectory("code/agents/.git")

        XCTAssertEqual(WorkspacesRoot.directory(forProject: project.path), path("code/.workspaces/agents"))
    }

    func test_directory_fallsBackToTheAppRootWhenTheParentIsInsideARepository() throws {
        let home = URL(fileURLWithPath: "/Users/someone")

        // A `.jj` directory two levels up: the walk has to keep going past
        // the immediate parent.
        let inMonorepo = try makeDirectory("mono/packages/app")
        _ = try makeDirectory("mono/.jj")
        XCTAssertEqual(
            WorkspacesRoot.directory(forProject: inMonorepo.path, home: home),
            "/Users/someone/.agents/workspaces/" + WorkspacesRoot.projectKey(forProject: inMonorepo.path)
        )

        // A `.git` FILE, as a linked worktree carries, counts as much as a
        // directory does.
        let inWorktree = try makeDirectory("worktree/app")
        try "gitdir: /elsewhere/.git/worktrees/x\n".write(
            to: base.appendingPathComponent("worktree/.git"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            WorkspacesRoot.directory(forProject: inWorktree.path, home: home),
            "/Users/someone/.agents/workspaces/" + WorkspacesRoot.projectKey(forProject: inWorktree.path)
        )
    }

    func test_directory_fallsBackToTheAppRootWhenTheParentIsNotWritable() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        let project = try makeDirectory("locked/app")
        let parent = base.appendingPathComponent("locked")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        try XCTSkipIf(
            fm.isWritableFile(atPath: parent.path),
            "the parent is still writable (running as root?), so the fallback cannot be exercised"
        )

        XCTAssertEqual(
            WorkspacesRoot.directory(forProject: project.path, home: home),
            "/Users/someone/.agents/workspaces/" + WorkspacesRoot.projectKey(forProject: project.path)
        )
    }

    // MARK: - fallbackDirectory / projectKey

    func test_fallbackDirectory_isProjectKeyedUnderDotAgentsWorkspaces() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directory = WorkspacesRoot.fallbackDirectory(forProject: "/Users/someone/code/agents", home: home)
        let key = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")

        XCTAssertEqual(directory, "/Users/someone/.agents/workspaces/" + key)
    }

    func test_projectKey_isBasenamePlusShortHash() {
        let key = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")
        let pattern = NSPredicate(format: "SELF MATCHES %@", "^agents-[0-9a-f]{8}$")

        XCTAssertTrue(pattern.evaluate(with: key), "expected agents-<8 hex>, got \(key)")
        XCTAssertEqual(key, WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents"), "deterministic")
    }

    func test_projectKey_ignoresTrailingSlashAndDotSegments() {
        let plain = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents")

        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/agents/"), plain)
        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/other/../agents"), plain)
        XCTAssertEqual(WorkspacesRoot.projectKey(forProject: "/Users/someone/code/./agents"), plain)
    }

    func test_projectKey_resolvesSymlinksToTheSameCheckout() throws {
        let real = try makeDirectory("real-project")
        let link = base.appendingPathComponent("linked-project")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            WorkspacesRoot.projectKey(forProject: link.path),
            WorkspacesRoot.projectKey(forProject: real.path)
        )
    }

    func test_projectKey_separatesSameNamedCheckouts() {
        let one = WorkspacesRoot.projectKey(forProject: "/Users/someone/code/website")
        let two = WorkspacesRoot.projectKey(forProject: "/Users/someone/scratch/website")

        XCTAssertTrue(one.hasPrefix("website-"))
        XCTAssertTrue(two.hasPrefix("website-"))
        XCTAssertNotEqual(one, two, "same basename, different checkout, different directory")
    }
}
