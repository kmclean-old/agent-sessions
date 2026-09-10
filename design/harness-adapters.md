# Harness adapters

For the planned app-level installer and settings UI, see
[Harness integration setup](harness-integration-setup.md).

Agents accepts lifecycle reports from native harness hooks over its control
socket. A report describes an observed event. The app's adapter for that
harness decides how the event changes phase and attention. Emitters do not
claim that a task succeeded, and they do not infer causal order from wall-clock
time.

## Lifecycle path

Hook reports, terminal-title events, and OS process exits enter
`TerminalCenter`, which rejects stale pane generations and superseded runs.
The registered `HarnessAdapter` turns a native event into a transition, and
the `HarnessLifecycle` reducer applies it. `AppStore` keeps that per-pane state,
builds the session summary, and publishes a read-only `AgentDashboardSnapshot`.

Runtime state is ephemeral. Its phase can be working, blocked, idle, or unknown;
a restored pane remains unknown until fresh evidence arrives. Unseen completion
is tracked separately. "Done" means that the harness emitted a terminal turn
event that the user has not seen, not that the user's task succeeded.

An integration with useful native events should add a `HarnessAdapter` to the
registry. A harness that emits the canonical events below needs no Swift
adapter.

## Socket protocol

Each connection sends one JSON object followed by a newline. The app applies
the event before replying with `{"ok":true}` and closing the connection. An
error reply has `ok:false` and an `error` string.

```json
{
  "cmd": "harness-event",
  "version": 1,
  "session": "workspace-row-id",
  "pane": "e9e280ce-7f7e-4db7-8dd0-d77e8f535e27",
  "generation": "7c252663-d6ed-4862-9796-72b6041907c1",
  "agent": "claude",
  "run_id": "4812:Wed Sep  9 10:12:45 2026",
  "pid": 4812,
  "event": "PermissionRequest",
  "agent_session_id": "native-conversation-id",
  "request_id": "toolu_123",
  "tool_name": "Bash",
  "message": "Approve this command?"
}
```

`session`, `pane`, and `generation` come from the environment that Agents puts
in the pane. `agent`, `run_id`, and `event` are also required. The optional
fields are `pid`, `sequence`, `agent_session_id`, `agent_home`, `prompt`,
`turn_id`, `request_id`, `tool_name`, `notification_type`, `source`, `message`,
`outcome`, `will_continue`, and `is_interrupt`.

A run identifies one OS harness process. Resuming the same native conversation
in a new process creates a new run. The Claude and Codex hook uses the nearest
harness ancestor's PID plus its OS start stamp. OMP creates one UUID when its
extension module loads and reports `process.pid`. A native conversation ID is
metadata and must not be used as the run ID.

Sequence numbers are useful only when the emitter owns the process and can
serialize delivery. The OMP extension does both. Separate Claude or Codex hook
processes cannot share a trustworthy counter, so the shell adapter omits it.
Neither adapter polls or uses recurring timers. Socket operations have a
two-second timeout so a stopped app cannot stall the harness indefinitely.

## Claude Code and Codex hooks

Install [agents-status.sh](../hooks/agents-status.sh) as a command hook for the
native lifecycle events that the harness exposes. One script supports both
harnesses. Existing installations keep using the legacy `session-event`
contract outside panes that have `AGENTS_PANE_GENERATION`; this preserves
compatibility with older Agents builds.

Claude Code can register the script for `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
`Notification`, `Stop`, and `SessionEnd`. Codex installations that expose the
same JSON hook contract can point those lifecycle hooks at the same command.
The script drains stdin even when the current terminal is not Agents.

The process walk suppresses nested harnesses. A Claude hook payload with an
`agent_id` is also suppressed because it belongs to a native subagent, not the
root invocation shown by the pane. When the walk cannot identify the nearest
harness process, the script sends the older attention report instead of
inventing a PID or run identity.

Claude's native events leave two gaps. An `idle_prompt` notification says that
Claude has been idle, but it does not prove that the turn just settled.
Interrupt reporting also varies by Claude Code version and hook configuration;
`Stop` is not inherently an interrupt. The adapter forwards `is_interrupt`
only when the native payload supplies it. A `Stop` hook may cause a
continuation, so an integration that receives a native continuation flag must
forward it as `will_continue`.

`SessionEnd` also needs its native reason. Claude documents `clear` and
`resume` reasons that end a conversation while the same process continues, so
the app resets conversation state for those reasons instead of retiring the
run. See [Claude Code hooks](https://code.claude.com/docs/en/hooks#sessionend).

## OMP extension

Install [agents-omp.ts](../hooks/agents-omp.ts) through OMP's extension loading
configuration. The module uses the public extension API shape and has no
dependency on this repository. It remains inactive unless all Agents pane
variables are present, and handlers report only when `ctx.mode === "tui"`.

The extension observes these native events:

| OMP event | Data forwarded |
| --- | --- |
| `session_start` | native conversation ID |
| `session_switch` | conversation ID and switch reason |
| `agent_start` | start of agent work |
| `agent_end` | `will_continue` and the last assistant stop reason |
| `auto_retry_start`, `auto_retry_end` | retry attempt and native result |
| `tool_approval_requested` | tool call ID, tool name, and reason |
| `tool_approval_resolved` | the same ID and approval result |
| `tool_execution_start` for `ask` | tool call ID and tool name |
| `tool_execution_end` for `ask` | the same ID and execution result |
| `session_shutdown` | process shutdown |

OMP can emit `agent_end` while retry or continuation maintenance is pending.
The extension forwards native `willContinue`, which OMP calculates after its
maintenance routing has decided whether to continue. It does not infer that
decision from a momentary idle reading. Retry start and end events give the app
the corresponding native transition.

## Canonical adapter events

Other harness integrations can avoid a harness-specific mapping by emitting
the following event names with the same version 1 envelope:

| Event | Required or relevant fields | Meaning |
| --- | --- | --- |
| `registered` | run identity, optional `pid` | The app may track the run. |
| `working` | optional `turn_id` or `source` | The harness is doing work. |
| `blocked` | `request_id`, optional `message` | The harness needs user input. |
| `resolved` | the same `request_id` | That request no longer blocks work. |
| `settled` | optional `outcome`, `is_interrupt` | The current turn reached a native terminal event. |
| `exited` | exact process identity when available | The harness process ended. |

Allowed terminal outcomes are `completed`, `interrupted`, and `failed`.
Approval and question results belong to their request transitions rather than
the terminal outcome of the agent's work. A dashboard may display the phase
and the native outcome, but it must not turn a lifecycle event into a claim
that the user's task succeeded.

An exit observer needs the exact process PID. Emitters that cannot identify it
should omit `pid`; they must not select an approximate ancestor. Keep request
IDs unchanged between `blocked` and `resolved`, and preserve native turn IDs
when they exist. These identifiers provide causal matching without synthetic
timestamps or polling.
