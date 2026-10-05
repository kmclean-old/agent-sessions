import CryptoKit
import Foundation

/// Where a project's workspaces live on disk: beside the project, at
/// `<parent>/.workspaces/<basename>`, so a workspace has exactly the
/// project's own ancestors.
///
/// Beside the project rather than inside it, because a directory nested in
/// the project is hostile to everything else that touches the tree:
/// `git clean -fdx` at the project root deletes every nested jj workspace
/// (a jj workspace carries only a `.jj` directory, so git's
/// nested-repository guard does not apply), every indexer, backup, and sync
/// client has to be told to skip it, and the project can never have a
/// directory of that name of its own. Nesting also loads the project's root
/// CLAUDE.md twice — once from the main checkout as an ancestor and once
/// from the workspace's own copy, possibly at different versions.
///
/// Beside the project rather than under an app-owned root such as
/// `~/.agents/workspaces`, because everything that discovers configuration
/// by walking up from the working directory — Claude Code's CLAUDE.md
/// chain, direnv's `.envrc`, whatever comes next — keys off filesystem
/// position. A workspace under `~/.agents` has the home directory as its
/// only meaningful ancestor and loses all of that. A sibling has the
/// project's own ancestors, so a session there runs under the same
/// instructions and environment as one started in the project itself.
/// (VCS identity never depended on this: git's `includeIf "gitdir:"` and
/// jj's `--when.repositories` both resolve to the main repository.)
///
/// One `.workspaces` per parent, with a directory per project basename: the
/// CLI mints a workspace's name against ONE project's registry, so two
/// projects can both produce `quiet-otter`, and a shared bucket would make
/// that a destination collision. Two checkouts with the same basename
/// cannot share a parent, so nothing more is needed to keep them apart.
///
/// Two cases a sibling cannot serve fall back to the app-owned root
/// `~/.agents/workspaces/<basename>-<hash>`, outside every repository and
/// hashed because same-named checkouts do share that root. A project whose
/// parent is itself inside a repository — a project nested in a monorepo,
/// say — would get its sibling nested in THAT repository, with every hazard
/// above one level up. And a parent the user cannot write to has no room
/// for a sibling at all.
enum WorkspacesRoot {
    static let defaultHome = FileManager.default.homeDirectoryForCurrentUser

    /// The directory the CLI is given as `--workspaces-root` for `projectPath`.
    static func directory(forProject projectPath: String, home: URL = defaultHome) -> String {
        let project = canonicalURL(forProject: projectPath)
        let parent = project.deletingLastPathComponent().standardizedFileURL
        guard project.pathComponents.count > 1,
              FileManager.default.isWritableFile(atPath: parent.path),
              !isInsideRepository(parent)
        else {
            return fallbackDirectory(forProject: projectPath, home: home)
        }
        return parent
            .appendingPathComponent(".workspaces")
            .appendingPathComponent(project.lastPathComponent)
            .path
    }

    /// `~/.agents/workspaces/<key>`: the app-owned root, used only when a
    /// sibling directory is impossible (see the type comment).
    static func fallbackDirectory(forProject projectPath: String, home: URL = defaultHome) -> String {
        home.appendingPathComponent(".agents")
            .appendingPathComponent("workspaces")
            .appendingPathComponent(projectKey(forProject: projectPath))
            .path
    }

    /// `<basename>-<8 hex chars>`, stable across trailing slashes, `..`
    /// segments, and symlinks: the hash is over the resolved path, so the
    /// same checkout always maps to the same directory however it was named.
    static func projectKey(forProject projectPath: String) -> String {
        let canonical = canonicalURL(forProject: projectPath).path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = (canonical as NSString).lastPathComponent
        return "\(name)-\(short)"
    }

    /// Whether `directory` or any directory above it is a repository root:
    /// one holding a `.git` entry (a directory, or the file a linked
    /// worktree carries) or a `.jj` directory. The probe starts at
    /// `directory` itself, so callers pass the project's PARENT — the
    /// project is a repository by definition.
    static func isInsideRepository(_ directory: URL) -> Bool {
        repositoryRoot(containing: directory) != nil
    }

    /// The nearest repository root at or above `directory` — the first
    /// directory, walking up, that holds a `.git` entry or a `.jj`
    /// directory — or nil when nothing above it is a repository. Nearest,
    /// not outermost, which is what `git rev-parse --show-toplevel` and
    /// `jj root` answer: a linked worktree or a jj workspace is its own
    /// root (it carries its own `.git` file or `.jj`), and so is a
    /// repository nested inside another. That is also the directory a user
    /// adding the project by hand would pick, which is why `open-session`
    /// registers an unknown directory's project here (see
    /// `OpenSessionPlacement`). Lexical: the result is spelled the way
    /// `directory` was, links and all.
    static func repositoryRoot(containing directory: URL) -> URL? {
        let fm = FileManager.default
        var cursor = directory.standardizedFileURL
        while true {
            for marker in [".git", ".jj"]
            where fm.fileExists(atPath: cursor.appendingPathComponent(marker).path) {
                return cursor
            }
            let next = cursor.deletingLastPathComponent().standardizedFileURL
            if next.path == cursor.path { return nil }
            cursor = next
        }
    }

    /// Standardized and symlink-resolved, so a project reached through a
    /// link gets the workspaces of the checkout it actually is — which is
    /// also where a shell spawned there ends up, since a shell's working
    /// directory is the physical path.
    private static func canonicalURL(forProject projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
    }
}
