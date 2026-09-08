# Native split panes

## Decision

Each session uses native libghostty surfaces owned by `TerminalCenter`.
Review tools run in ordinary sessions or panes. The app does not own their
launch, feedback, or completion protocol.

## Native split panes

The hard parts of a multiplexer — virtual terminals, buffer reparsing,
detach — are not needed: libghostty provides real surfaces. What remains is a
layout and focus problem.

### Layout model

Each session owns a small binary tree: a leaf is a pane with a stable UUID; an
interior node has an orientation and a split ratio. It is a value type with
pure operations (split, close, collapse, resize) and is unit-tested on its
own, independent of AppKit.

### Surface ownership

`TerminalCenter` owns entries keyed by pane id, grouped by session.
`SessionDelegateProxy` closes over a pane id; attention signals from any pane
aggregate up to the session row, and the focused pane's title drives the row
title. New panes spawn the user's login shell in the session's working
directory with the same stamped environment, including the shared
`AGENTS_SESSION_ID`.

### View layer

All pane surfaces remain direct children of the one container view, mounted
once and never reparented — reparenting blanks a live Metal surface, the
constraint `TerminalHostView` is already built around. The layout tree drives
constraints; thin divider views provide drag-to-resize. `NSSplitView` is not
used: inserting one on first split would force reparenting the existing
surface.

### Focus and interaction

One focused pane per session, with a minimal visual indication. Click to
focus. Keyboard commands: split right, split down, close pane, move focus
directionally. Selection, clipboard, scrollback, and drag and drop are per
pane and remain fully native.

### Lifecycle

- A pane's process exit collapses its tree node. The last pane's exit removes
  the session row through the existing `terminalDidClose` path.
- Close and quiesce tear down all of a session's panes.
- The resume hint prints once, in the session's initial pane only.
- Split layout is not persisted across relaunch: the processes do not survive
  anyway, so a restored session starts with a single pane and the existing
  resume behavior.

## Testing

Automated coverage:

- per-session environment stamping, including `AGENTS_SESSION_ID`;
- layout tree operations: split, close, collapse, ratio adjustment;
- pane exit collapses the right node; last-pane exit removes the correct row;
- attention aggregation and title routing across panes;
- resume hint prints once and only in the initial pane.

Manual matrix:

1. Run a tool in one session and another tool in a separate session or pane;
   switching between them preserves their terminals and focus.
2. Create, resize, and close splits; run agents in separate panes; verify
   attention dots, titles, and focus movement.
3. Exercise scrollback, selection, clipboard, mouse, and drag and drop per
   pane.
4. Relaunch: restored sessions come back as a single pane with one resume
   hint.

Run `bb test` for the macOS test suite.

## Non-goals

- tmux or any multiplexer as a terminal substrate;
- detach/reattach or process persistence beyond resume metadata;
- pane zoom, broadcast input, or pane swapping in v1;
- persisting split layout across relaunch;
- windows or tabs beyond the sidebar.
