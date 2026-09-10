# Harness integration setup

Status: agreed direction; installer and settings UI are not implemented.
Recorded 2026-09-09 for a fresh implementation context.

Agents should configure harness integrations once per user configuration home.
The user explicitly rejected per-project setup. The proposed entry point is
**Settings → Harness Integrations**, with Install, Repair, and Remove actions.
Normal harness commands should work in any project after installation.

## Existing foundation

The event-driven lifecycle implementation is complete. See
[Harness adapters](harness-adapters.md) for the protocol and
[the README](../README.md#with-the-hook-for-real-agent-state) for manual setup.

- `hooks/agents-status.sh` reports Claude Code and Codex command-hook events.
- `hooks/agents-omp.ts` reports native OMP extension events.
- `TerminalCenter` validates pane generations and observes process exits.
- `HarnessAdapter` maps native events; `HarnessLifecycle` reduces transitions.
- `AppStore` owns per-pane state and derives session summaries.
- The Waiting pane consumes one read-only `AgentDashboardSnapshot`.

The installer must preserve that separation. Setup manages files and harness
configuration; it does not infer or write runtime lifecycle state. Reporting
remains driven by hooks, terminal callbacks, and kernel process notifications.
There must be no periodic session scans, busy waiting, or model calls.

## Installation experience

Each settings row represents a harness and a configuration home. Detect known
homes and allow the user to select another directory. Support multiple homes
for the same harness, such as personal and work accounts. A GUI-launched app
cannot assume that its environment contains variables set by shell wrappers.

Install should prepare a concrete change showing the target configuration and
the Agents entries it will add. Repair should restore missing or outdated
Agents entries. Remove should remove only entries owned by this integration.
Repeated installation must not duplicate hooks.

Ship the emitters with the app and install them at a stable Application Support
path. Harness settings should not depend on a development checkout or on the
app bundle staying in one location. An illustrative destination is
`~/Library/Application Support/Agents/integrations/`; the exact layout and
versioning scheme remain to be chosen. Quote paths correctly, including spaces.

Use each harness's native user-level configuration mechanism:

| Harness | Setup mechanism |
| --- | --- |
| Claude Code | Merge command hooks into the chosen home's `settings.json`. |
| Codex | Merge supported command hooks into the chosen home's `hooks.json`; retain native hook trust review. |
| OMP | Register the extension for persistent discovery in the chosen profile. |

Verify supported events, extension discovery, and trust behavior against the
installed harness versions before implementing those writers. The runtime
adapter's ability to recognize an event does not prove that every harness
version exposes it.

Integrations remain installed globally but report only in Agents panes, using
the environment stamped into each pane. New panes in the updated app receive
`AGENTS_PANE_GENERATION`; existing shells cannot acquire it retroactively.

## Configuration ownership

Preserve unrelated settings, hooks, matchers, and user edits. Keep a record of
the integration's installed files and entries so repair and removal can be
precise. A removed configuration home must not cause repair to recreate it
silently.

Configuration files may be symlinks into dotfiles repositories. Follow the
link and preserve it when writing. Detect intervening edits before applying a
prepared change. Failed installation should leave recoverable configuration
and accurately report which steps completed.

Give Agents hooks their own appropriate matcher groups; do not inherit a
tool-specific matcher from an unrelated hook. When migrating existing manual
setup, recognize the current checkout-based command and avoid running both
copies. Never manufacture a harness trust approval to make setup look complete.

## Configuration and runtime evidence

Display configuration status separately from runtime evidence. Valid files
mean configured; an accepted lifecycle report means a live harness has reported.
An idle harness may send nothing for a long time, so silence alone must not mark
the integration broken or disconnected.

Configuration inspection can run when settings opens, after an action, and on
explicit refresh. Runtime evidence should reuse accepted events from the
existing control path. Neither needs a recurring polling loop.

## First implementation slice

Build a setup service with harness-specific configuration adapters, separate
from the runtime event adapters. Start with inspect, prepare install/repair,
apply, and remove operations against temporary configuration homes. Then wire
the service into Settings and package the emitter files with the app.

Acceptance checks should cover repeated installation, preservation of unrelated
hooks and symlinks, paths with spaces, multiple homes, migration from manual
setup, partial failures, intervening edits, and removal of owned entries only.
Verify that a fresh harness in an Agents pane reports through the existing
lifecycle path and that the same integration stays inactive in other terminals.

Resolve during implementation: how Debug and Release apps share installed
emitters, how emitter versions are upgraded, and how shared files are retained
when one of several configured homes removes its integration.
