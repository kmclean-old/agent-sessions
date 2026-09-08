# Hidden projects

The user-facing vocabulary is **Hide Project**, **Hidden**, and **Show in
Sidebar**. The internal archive/restore names and persisted keys below are
retained for compatibility; they describe the same lifecycle.

## Mental model

The sidebar lists the projects you are working in. A project you are not
working in right now can be hidden: it leaves the list, its terminals stop,
and everything the app knew about it is kept whole — its sessions with their
names, agent titles and resume hints, and its workspace rows. Restoring the
project puts all of that back exactly as it was.

Hiding is bookkeeping in the app, not an operation on the project. Nothing
on disk changes: not the project directory, not its workspaces, not its
repository. That is the same promise Remove Project already makes; hiding
adds the promise that the app's own record survives too.

Remove Project remains the way to forget a project entirely, whether it is
active or archived.

## Invariants

1. Archiving a project preserves every session row and workspace row it had,
   in order, and restoring it reinstates them unchanged. Session identity
   (ids) survives, so persisted resume metadata and terminal-view identity
   are the same after a restore as before the archive.
2. Archiving touches nothing on disk and never calls the workspace engine.
3. Archived rows are never live: they are not in `sessions`, `workspaces` or
   `projects`, so no consumer of those arrays — the sidebar, the dashboard,
   the Dock badge, navigation, workspace operations — needs to know archiving
   exists. Attention state for archived sessions is dropped, exactly as it is
   for closed sessions; it describes processes that no longer exist.
4. A path is in at most one place: active or archived, never both. Adding a
   project whose path is archived restores it rather than creating a second
   copy.
5. Every terminal in the project is stopped before its rows are parked, the
   same way Remove Project stops them. A session that was running an agent
   keeps its resume hint, so reopening it after a restore prints the resume
   command just as it does after a relaunch.
6. Archiving is reversible in one action and therefore asks no confirmation.
   Removing is not, and keeps its confirmation.

## Experience

**Hiding.** Swiping a project row leftward reveals **Hide**; a full swipe
hides it outright. The same action appears in the row's ellipsis and
context menus, and in the File menu as **Hide Project**. Selection moves to
the next project's first session, or the previous project's when the hidden
one was last.

**Footer.** A fixed footer, separated from the scrolling project list by an
inset divider, groups a muted **Hidden** button and count on the left with a
compact, softly filled **Add project** button on the right. The hidden
control uses an eye-slash icon and disappears when its count reaches zero.
Both actions have subtle hover and press feedback and use semantic colors
for light and dark appearances.

**Hidden projects.** Clicking **Hidden** opens a popover with a bounded,
scrollable list, most recently hidden first. Each row shows the name and
path. Clicking a row, choosing **Show in Sidebar** from its menu, or swiping
it rightward shows the project and dismisses the popover. Its first session
is selected; a project without saved sessions gets a fresh one. The row's
menus also offer **Remove Project…** with the usual confirmation. Removing
the last hidden project dismisses the popover.

**Naming.** "Hidden" describes a deliberate choice to take a project out of
the sidebar. It is not an archive or an automatically inferred inactivity
status. "Add project" opens an existing folder rather than creating one.

## Integration design

- `ArchivedProject` is a persisted record of `{path, archivedAt, sessions,
  workspaces}`. `PersistedState` gains an optional `archivedProjects` array,
  decoded as empty when absent, so existing state files load unchanged and
  the version stays at 2. `archivedAt` is recorded now so a later automatic
  "archive projects idle for N days" needs no migration; nothing tracks
  per-project activity yet.
- `AppStore.archiveProject(_:)` mirrors `removeProject(_:)` — stop terminals,
  drop live rows, prune attention, drop the lifecycle token, clear
  project-working-copy attention and any close-workspace presentation for
  the project — then parks the rows in `archivedProjects` instead of
  discarding them.
- `AppStore.restoreProject(_:)` appends the project to the end of the active
  list, the same place Add Project puts a new one, reinstates its rows, mints
  a fresh lifecycle token, and seeds the session counters for the restored
  targets so a new session continues the numbering rather than reusing
  "Session 1".
- `removeProject(_:)` also purges the path from `archivedProjects`, so one
  function forgets a project wherever it is.
- `AppAction.archiveProject` is menu-only like `removeProject`, and resolves
  its target the same way (selected session's project, else the sole project).

## Delivery sequence

1. Model and store: `ArchivedProject`, persistence, archive/restore/remove
   semantics, with store tests for the invariants above.
2. Action and menus: `AppAction.archiveProject`, Hide Project menu item, action tests.
3. Sidebar: project rows with the Hide swipe; the footer and hidden-project
   popover with Show in Sidebar.
4. README and TODO.

## Non-goals

- Automatic archiving by inactivity. The persisted shape allows it later.
- Project reordering and per-project collapse. The row restructure in step 3
  is the prerequisite for both; neither is built here.
- Any change to what Remove Project does to on-disk state (nothing).
