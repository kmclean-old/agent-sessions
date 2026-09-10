# Harness integration setup

Status: implemented in Settings → Harness Integrations.

Agents configures harness integrations once per user configuration home in
**Settings → Harness Integrations**, with Install, Repair, and Remove actions.
Normal harness commands use the integration in any project after installation.

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

The app bundles both emitters and installs them under
`~/Library/Application Support/Agents/integrations/emitters/<sha256>/`.
The hash identifies the file contents. Debug and Release builds share identical
emitters; different versions have separate paths. Settings do not depend on a
development checkout or the app bundle staying in one location. Commands quote
absolute paths, including spaces and apostrophes.

Use each harness's native user-level configuration mechanism:

| Harness | Setup mechanism |
| --- | --- |
| Claude Code | Merge command hooks into the chosen home's `settings.json`. |
| Codex | Merge supported command hooks into the chosen home's `hooks.json`; retain native hook trust review. |
| OMP | Write an owned `extensions/agents-integration.ts` loader in the chosen agent home. |

The configuration adapters use the following compatibility baselines:

- Claude Code 2.1.261: session start/end, prompt submission, pre/post tool,
  permission request, tool failure, notification, stop, and stop failure.
  See the [native hooks reference](https://code.claude.com/docs/en/hooks).
- Codex 0.153.4: session start/end, prompt submission, pre/post tool, permission
  request, stop, and interrupt. It does not expose `Notification` or
  `PostToolUseFailure`. Users review trust through `/hooks`; Agents does not
  write approval hashes or bypass settings. See the
  [native hooks guide](https://learn.chatgpt.com/docs/hooks).
- OMP 18.0.11: a regular TypeScript loader uses native user-extension discovery.
  It re-exports the installed emitter without editing profile settings. See
  [native discovery](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/discovery/builtin.ts).

Native trust, disabled-hook settings, command-line flags, and harness policies
can prevent execution. Configuration status does not imply that a harness has
accepted or run the integration.

Integrations remain installed globally but report only in Agents panes, using
the environment stamped into each pane. New panes in the updated app receive
`AGENTS_PANE_GENERATION`; existing shells cannot acquire it retroactively.

## Configuration ownership

Preserve unrelated settings, hooks, matchers, and user edits. The shared
`integrations/registry.json` records each home, emitter path, and exact owned
entries so repair and removal can be precise. A removed configuration home must
not cause repair to recreate it silently.

Configuration files may be symlinks into dotfiles repositories. Follow the
link and preserve it when writing. Detect intervening edits before applying a
prepared change. Failed installation should leave recoverable configuration
and accurately report which steps completed.

Preparation reads files without changing them. Apply acquires a shared setup
lock, checks file contents, permissions, symlink targets, and home identity,
then saves recovery copies before writing. The ownership record is written
last. On failure, completed writes are rolled back where the saved assumptions
still hold. Intervening user edits are preserved; the error gives the recovery
directory. Rollback never recreates a removed home.

Different homes can share emitter files, but two homes cannot independently
own the same configuration file through symlinks. Setup directs the user to
the already registered home in that case. Edited owned hooks are preserved
on removal and flagged before repair. An edited OMP loader must be resolved
before repair or removal.

Give Agents hooks their own appropriate matcher groups; do not inherit a
tool-specific matcher from an unrelated hook. When migrating existing manual
setup, recognize the current checkout-based command and avoid running both
copies. Existing manual OMP registrations in profile settings or discovered
extensions require manual resolution before installation, to avoid duplicate
reports. Never manufacture a harness trust approval to make setup look complete.

OMP inspection parses YAML and legacy JSON settings without rewriting them.
It checks declared files and directories as well as native extension discovery.
Relative extension registrations must be changed to absolute paths before
setup: OMP resolves them against each project's working directory, which a
global installer cannot determine in advance.

## Configuration and runtime evidence

Display configuration status separately from runtime evidence. Valid files
mean configured; an accepted lifecycle report means a live harness has reported.
An idle harness may send nothing for a long time, so silence alone must not mark
the integration broken or disconnected.

Configuration inspection can run when settings opens, after an action, and on
explicit refresh. Runtime evidence should reuse accepted events from the
existing control path. Settings displays the last accepted report for each
harness during this app launch. This evidence is not persisted or attributed
to an individual configuration home. Silence never expires it. Neither
configuration inspection nor runtime evidence needs a recurring polling loop.

## Implementation and verification

`HarnessSetupService` prepares and applies file changes; `HarnessHookConfiguration`
handles native JSON hook entries. `HarnessIntegrationsModel` and its Settings
view own discovery, directory selection, previews, and explicit actions.
`AppStore` records runtime evidence only after the lifecycle reducer accepts an
event. Installation does not write lifecycle state.

Discovery includes existing standard Claude and Codex homes, sibling account
homes with configuration files, OMP's default and named profile homes, relevant
environment overrides, and recorded installations. Users can add directories
when shell wrappers or custom layouts are not visible to the GUI app. OMP's
selected directory is the profile's `agent` home, which contains `extensions`.

Tests use temporary homes and injected emitters. They cover repeated setup,
unrelated hooks and matchers, symlinks, quoted paths, migration, multiple homes,
intervening edits, partial failures and recovery, deleted homes, emitter
versions, native discovery, and removal of owned entries. Settings model tests
cover persisted directory selections, cancellation, action results, and stale
previews. Lifecycle tests keep configuration status separate from accepted
runtime evidence.

Removing an integration detaches the selected home. Shared emitter versions
are retained for other homes, running harnesses, and other app builds; automatic
garbage collection is not implemented. The registry format is versioned, and
an unknown format is rejected without rewriting it.
