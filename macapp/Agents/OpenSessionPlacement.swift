import Darwin
import Foundation

/// Where in the sidebar a session opened over the control socket belongs
/// (see `ControlOpenSession`, `AppStore.openSession`). The request names a
/// directory, not a row, so this answers the question the user answers by
/// hand when they pick where to press New Session: which project or
/// workspace is this directory part of?
///
/// The answer is the DEEPEST registered directory that contains it — the
/// directory itself or an ancestor — among every project root and every
/// workspace, hidden ones included. Deepest, because projects can nest (a
/// package registered on its own inside a monorepo that is registered too)
/// and the narrower one is the one the user meant to work in; and a
/// workspace lives beside its project rather than inside it (see
/// `WorkspacesRoot`), so a directory in a workspace is only ever contained
/// by that workspace and the workspace wins without a tiebreak.
///
/// Hidden projects take part on purpose. A hidden project is one the user
/// parked, not one they forgot, and the app's own rule for asking to work
/// in a hidden project's directory again — Add Project on its path — is
/// to bring it back, rows and all, rather than open a second copy beside
/// it (see `AppStore.addProject`). Opening a session there is the same
/// request, so it gets the same answer.
///
/// When nothing contains the directory, it becomes a new project rooted at
/// its repository root, or at the directory itself outside any repository
/// — the directory a user adding it by hand would pick. Registering the
/// subdirectory instead would give the repository a second, narrower
/// project the first time a tool opened a session in, say, its `src/`.
enum OpenSessionPlacement: Equatable {
    /// A live project root or workspace contains the directory.
    case target(TargetRef)
    /// A hidden project's root or one of its workspaces contains the
    /// directory; the project must come back before the session can join it.
    case hiddenTarget(TargetRef)
    /// Nothing registered contains the directory: add a project at this path.
    case newProject(path: String)

    /// `canonicalPath` and `repositoryRoot` are the two places this looks
    /// at the disk, injectable so the rule can be pinned with made-up paths.
    /// Containment is decided on canonical paths — links resolved — so a
    /// directory reached through a symlink still lands in the project it
    /// physically is, the way a shell spawned there would report it; the
    /// path a new project is registered under keeps the caller's spelling.
    static func resolve(
        directory: String,
        projects: [Project],
        workspaces: [WorkspaceRow],
        hidden: [ArchivedProject],
        canonicalPath: (String) -> String = OpenSessionPlacement.canonicalPath,
        repositoryRoot: (String) -> String? = {
            WorkspacesRoot.repositoryRoot(containing: URL(fileURLWithPath: $0))?.path
        }
    ) -> OpenSessionPlacement {
        let target = canonicalPath(directory)

        var candidates: [(path: String, placement: OpenSessionPlacement)] = []
        for project in projects {
            candidates.append((project.path, .target(.root(projectPath: project.path))))
        }
        for workspace in workspaces {
            candidates.append((
                workspace.path,
                .target(.workspace(projectPath: workspace.projectPath, name: workspace.name))
            ))
        }
        for project in hidden {
            candidates.append((project.path, .hiddenTarget(.root(projectPath: project.path))))
            for workspace in project.workspaces {
                candidates.append((
                    workspace.path,
                    .hiddenTarget(.workspace(projectPath: workspace.projectPath, name: workspace.name))
                ))
            }
        }

        // The longest canonical ancestor is the deepest. Strictly longer,
        // so the first of two candidates at one path — which state should
        // never hold — wins, and live rows (listed first) beat hidden ones.
        var best: (length: Int, placement: OpenSessionPlacement)?
        for candidate in candidates {
            let ancestor = canonicalPath(candidate.path)
            guard contains(ancestor, target) else { continue }
            if best == nil || ancestor.count > best!.length {
                best = (ancestor.count, candidate.placement)
            }
        }
        if let best { return best.placement }
        return .newProject(path: repositoryRoot(directory) ?? directory)
    }

    /// Whether `path` is `ancestor` or lies beneath it, by whole path
    /// components — `/code/app` does not contain `/code/application`.
    static func contains(_ ancestor: String, _ path: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// `path` standardized and, when it exists, with every symlink resolved
    /// by `realpath(3)` — which, unlike `URL.resolvingSymlinksInPath`, never
    /// strips `/private` back off a path that exists, so `/tmp/x` and
    /// `/private/tmp/x` always meet. A path that doesn't exist (a project
    /// whose directory has gone) is compared as written, standardized.
    static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
