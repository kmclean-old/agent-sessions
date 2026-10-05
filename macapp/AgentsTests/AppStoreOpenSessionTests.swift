import XCTest
@testable import Agents

/// `AppStore.openSession` — what the control socket's `open-session` does
/// to the sidebar — against real directories, since finding the project
/// for an unknown directory means looking for its repository on disk.
/// Every test builds its sidebar through the store's public API, like
/// `AppStoreTests`, and reads back the rows, the selection, and what the
/// terminals were asked to run.
@MainActor
final class AppStoreOpenSessionTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("AppStoreOpenSessionTests-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Resolved once so expected paths are spelled the way the store
        // sees them (macOS temp dirs sit behind a symlink).
        base = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> String {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func request(_ directory: String, title: String? = nil) -> ControlOpenSession {
        ControlOpenSession(workingDirectory: directory, command: "claude-seeq attach 7ea9eb92", title: title)
    }

    func testASessionOpenedInsideAProjectJoinsItSelectedAndLabelled() throws {
        let project = try makeDirectory("agents")
        let directory = try makeDirectory("agents/macapp")
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: project)

        let id = store.openSession(request(directory, title: "Attach: fix the parser"))

        XCTAssertEqual(store.projects.map(\.path), [project], "no second project for a subdirectory")
        let row = try XCTUnwrap(store.sessions.first { $0.id == id })
        XCTAssertEqual(row.target, .root(projectPath: project))
        XCTAssertEqual(row.displayName, "Attach: fix the parser")
        XCTAssertNil(row.customName, "the label is the row's name, not a rename an agent title can never replace")
        XCTAssertEqual(store.selection, id)
        XCTAssertEqual(spy.stagedLaunches.count, 1)
        XCTAssertEqual(spy.stagedLaunches.first?.sessionID, id)
        XCTAssertEqual(spy.stagedLaunches.first?.command, "claude-seeq attach 7ea9eb92")
        XCTAssertEqual(
            spy.stagedLaunches.first?.workingDirectory, directory,
            "the pane opens where it was asked to, below the project root"
        )
    }

    func testWithoutATitleTheRowIsNumberedLikeAnyOther() throws {
        let project = try makeDirectory("agents")
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: project) // Session 1

        let id = store.openSession(request(project))

        XCTAssertEqual(store.sessions.first { $0.id == id }?.name, "Session 2")
    }

    func testTheDeepestContainingProjectOrWorkspaceGetsTheSession() async throws {
        let monorepo = try makeDirectory("monorepo")
        let package = try makeDirectory("monorepo/packages/web")
        let workspacePath = try makeDirectory(".workspaces/monorepo/quiet-otter")
        let fake = FakeWorkspaceEngine()
        let (store, _, _) = TestSupport.makeStore(engine: fake)
        store.addProject(path: monorepo)
        store.addProject(path: package)
        fake.nextCreateResult = .success(
            WorkspaceRow(projectPath: monorepo, name: "quiet-otter", path: workspacePath, label: nil)
        )
        await store.createWorkspace(in: monorepo)

        let inPackage = store.openSession(request(try makeDirectory("monorepo/packages/web/src")))
        let inMonorepo = store.openSession(request(try makeDirectory("monorepo/packages/api")))
        let inWorkspace = store.openSession(request(workspacePath))

        let target = { (id: String) in store.sessions.first { $0.id == id }?.target }
        XCTAssertEqual(target(inPackage), .root(projectPath: package))
        XCTAssertEqual(target(inMonorepo), .root(projectPath: monorepo))
        XCTAssertEqual(target(inWorkspace), .workspace(projectPath: monorepo, name: "quiet-otter"))
        XCTAssertEqual(store.projects.map(\.path), [monorepo, package])
    }

    func testAnUnknownDirectoryInARepositoryAddsTheRepositoryAsAProject() throws {
        let repository = try makeDirectory("command-centre")
        try makeDirectory("command-centre/.jj")
        let directory = try makeDirectory("command-centre/src/web")
        let (store, spy, stateURL) = TestSupport.makeStore()

        let id = store.openSession(request(directory))

        XCTAssertEqual(store.projects.map(\.path), [repository], "the project the user would have added by hand")
        XCTAssertEqual(
            store.sessions.map(\.id), [id],
            "the opened session is the project's only one — Add Project's own first session would be a shell nobody asked for"
        )
        XCTAssertEqual(store.sessions.first?.target, .root(projectPath: repository))
        XCTAssertEqual(spy.stagedLaunches.first?.workingDirectory, directory)
        XCTAssertEqual(store.selection, id)

        // A project like any other: it outlives a relaunch.
        let reloaded = AppStore(terminals: SpyTerminals(), stateURL: stateURL, engine: FakeWorkspaceEngine())
        XCTAssertEqual(reloaded.projects.map(\.path), [repository])
        XCTAssertEqual(reloaded.sessions.map(\.id), [id])
    }

    func testAnUnknownDirectoryOutsideAnyRepositoryBecomesItsOwnProject() throws {
        let directory = try makeDirectory("scratch/notes")
        let (store, _, _) = TestSupport.makeStore()

        store.openSession(request(directory))

        XCTAssertEqual(store.projects.map(\.path), [directory])
    }

    func testAHiddenProjectComesBackWithItsRowsAndTheNewSessionOnly() throws {
        let project = try makeDirectory("parked")
        let (store, spy, _) = TestSupport.makeStore()
        store.addProject(path: project)
        let parked = store.sessions[0]
        store.renameSession(parked.id, to: "build server")
        store.addProject(path: try makeDirectory("other"))
        store.archiveProject(store.projects[0])
        XCTAssertEqual(store.archivedProjects.map(\.path), [project])

        let id = store.openSession(request(try makeDirectory("parked/src")))

        XCTAssertTrue(store.archivedProjects.isEmpty, "opening a session in a hidden project's directory brings it back, as adding it would")
        XCTAssertEqual(store.projects.last?.path, project, "back at the end of the list, where a restore puts it")
        XCTAssertEqual(
            store.sessions.filter { $0.projectPath == project }.map(\.id), [parked.id, id],
            "its parked session comes back as it was, and nothing else is added beside the opened one"
        )
        XCTAssertEqual(store.sessions.first { $0.id == parked.id }?.customName, "build server")
        XCTAssertEqual(store.sessions.first { $0.id == id }?.name, "Session 2", "numbering continues past the parked rows")
        XCTAssertEqual(store.selection, id)
        XCTAssertEqual(spy.stagedLaunches.map(\.sessionID), [id])
    }

    func testAProjectReachedThroughASymlinkIsStillTheProject() throws {
        let project = try makeDirectory("real/agents")
        try fm.createSymbolicLink(
            atPath: base.appendingPathComponent("link").path,
            withDestinationPath: base.appendingPathComponent("real").path
        )
        let (store, _, _) = TestSupport.makeStore()
        store.addProject(path: project)

        let id = store.openSession(request(base.appendingPathComponent("link/agents").path))

        XCTAssertEqual(store.projects.map(\.path), [project])
        XCTAssertEqual(store.sessions.first { $0.id == id }?.target, .root(projectPath: project))
    }
}
