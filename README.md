# Agents

> **Retired.** This was how I work with agents for the middle half of 2026.
> It has been superseded by [overview](https://github.com/kirahowe/overview).
> This repo is no longer maintained, and there are no more nightly builds.

A minimal native macOS app: a sidebar organizes terminal sessions under
project directories, with real [Ghostty](https://ghostty.org)-rendered
terminals (running your actual login shell) in the detail area.

## Prerequisites

- Xcode (macOS 15+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Babashka](https://babashka.org/): `brew install borkdude/brew/babashka`
- Temporary local checkout of
  [workstream-manager](https://github.com/kirahowe/workstream-manager) at
  `$HOME/code/projects/workstream-manager` (until the dependency is
  published). Set `WORKSTREAM_MANAGER_ROOT` to use a different checkout.

## Usage

```sh
bb run
```

This generates the Xcode project, builds it, and launches the app. Individual
steps are also available: `bb gen`, `bb build`, `bb clean`.

The generated `macapp/Agents.xcodeproj` and build output under `macapp/.build`
are gitignored — `bb gen` regenerates the project from `macapp/project.yml`
whenever you need it.

## Keyboard shortcuts

Open **Help ▸ Keyboard Shortcuts** (⇧⌘? by default), click a shortcut, and
press the new combination. Shortcuts must include Command (⌘), Control (⌃)
or Option (⌥), so plain typing and Shift-only typing still reach the terminal.
Standard macOS commands such as Copy, Paste, and Quit are reserved. Conflicting app
shortcuts show the other action's name and must be resolved before saving.

**Save** applies all edits immediately and remembers them across launches.
**Cancel** discards the draft. Escape cancels an active recording first;
outside recording it closes the sheet without saving. Use the clear and
restore buttons beside each shortcut, or **Restore Defaults** for the whole
list. Clears and restores also take effect only after Save.

## Releases

There is one release channel: a rolling `nightly` prerelease on GitHub,
which the Nightly workflow (`.github/workflows/nightly.yml`) rebuilds from
`main` every morning at 09:00 UTC, skipping the run when nothing has
changed. The same workflow regenerates the signed Sparkle appcast attached
to that release, and that appcast is what **Agents ▸ Check for Updates…**
reads — so publishing a release and making it available to the updater are
one act.

To publish `main` now rather than waiting for the schedule:

```sh
bb publish
```

This dispatches the workflow for `main`, watches the run to completion, and
prints the resulting release. It refuses if the local `main` bookmark is not
what GitHub has, so an unpushed fix cannot be silently left out, and it does
nothing (successfully) when the current nightly is already built from
`main`. It needs the `gh` CLI, logged in with write access to the
repository. The build happens on GitHub rather than on the machine running
the task on purpose: the runner pins the SDK the app is compiled against,
and the appcast is signed with a key that exists only in the repository's
secrets.

## Workspaces

A workspace is an isolated draft of a project: agents read, write, and run
commands in it without touching the project's own files. Create one with
**New Workspace** (⌘N) from the File menu, or from a project's header menu —
either way you pick the project and can set an optional sidebar label (the
label is sidebar-only; it never renames the workspace). It lives on disk
beside the project, at `<parent>/.workspaces/<project>/<generated-name>` —
for `~/code/projects/agents` that is
`~/code/projects/.workspaces/agents/<generated-name>`. Beside rather than
inside, so nothing that walks the project's tree (`git clean -fdx`,
indexers, backups) ever meets it; beside rather than somewhere app-owned,
so a workspace has exactly the project's own ancestors, and a session there
picks up the same `CLAUDE.md` chain, `.envrc`, and anything else discovered
by walking up from the working directory. One `.workspaces` per parent with
a directory per project keeps two projects' generated names from colliding.
A project whose parent is itself inside a repository, or isn't writable,
gets its workspaces under `~/.agents/workspaces/<project>-<hash>/` instead,
outside every repository. It's a jj workspace or a git worktree depending
on the project, detected automatically — a colocated jj/git repo is treated
as jj. Each workspace keeps its own sessions in the sidebar, nested
underneath it.

### Closing a workspace

**Close Workspace…**, on a workspace row's context menu (or its ellipsis
button), or on the File menu for the selected session's workspace, opens one
sheet that covers every outcome:

- With changes to add, the sheet lists them in plain language and offers
  **Add Changes & Close** — add the draft to the project's shared progress,
  then remove the workspace — or the destructive **Close Without Adding…**,
  which asks once more before it proceeds.
- If some of those changes are undescribed, the sheet asks for a one-line
  summary before it will add them.
- With nothing to add, it just offers **Close Workspace** and **Cancel**.
- If the changes overlap newer project progress, the sheet says so and offers
  **Return to Workspace** or **Close Without Adding…** — it never offers an add
  it can predict would conflict. If a conflict only turns up once the add is
  under way, the changes are moved onto the latest project progress with the
  conflicts marked and the workspace stays open: resolve them there and close
  it again, or back out with `jj undo` (`git rebase --abort`).
- If the project has no shared progress yet — a brand-new repo — the sheet
  offers to set the project up with these changes as its starting point.

Closing stops every session in that workspace before anything changes, because
the workspace's files are about to be rewritten out from under them. The sheet
tells you how many sessions it will stop. If the close is refused — an overlap,
or the workspace changing mid-flight — the sessions come back as fresh shells;
a session that was running an agent gets its resume banner (see "Resuming
agent sessions after a restart" below).

After a successful add, the app also brings the project root's own unlanded
work up to date with the new progress, automatically — but only when no
sessions are open there, since updating it any other time would rewrite files
out from under a running agent. When it can't reconcile automatically, the
project header shows an orange triangle and its menu offers **Refresh Project
Workspace** instead. Nothing is lost either way, and other open workspaces are
never rewritten by someone else's close — each one reconciles with the latest
progress on its own, the next time it closes.

For the curious: adding changes means, under jj, rebasing the workspace's
commits onto trunk and moving the trunk bookmark; under git, rebasing the
`agents/<name>` branch, fast-forwarding trunk, and deleting the now-merged
branch. Either way the workspace is deregistered afterwards. Nothing is
copied aside first: the version control system's own record — jj's operation
log, git's reflog — is the safety net if an add ever needs unwinding by
hand. Closing without adding just deregisters the
workspace and moves its folder to the Bin — the commits stay in the
repository's history (jj) or on the `agents/<name>` branch (git), so they're
recoverable by hand.

## Hiding projects

A project you are not working in right now can be hidden from the sidebar.
Swipe its row leftward (two fingers on a trackpad) and choose **Hide**, or
swipe all the way; the same action is on the row's ellipsis and context
menus, and on the File menu as **Hide Project** for the selected session's
project.

Hiding stops the project's terminals, exactly as removing it does, but keeps
its sessions with their names, agent titles and resume hints, and its
workspace rows. Nothing on disk changes — not the project, not its
workspaces, not its repository — so there is nothing to confirm.

The sidebar footer groups **Hidden**, with a count, beside **Add project**.
Click **Hidden** to open a list of the projects you chose to hide, most
recently hidden first, each with its path under its name. Click a project
(or swipe it rightward and choose **Show in Sidebar**) to bring it back at
the end of the project list with its sessions as they were. The popover
closes and its first session is selected; opening a saved session prints
its resume hint, as after a relaunch. Adding a hidden project's directory
brings it back the same way rather than opening a second copy.
**Remove Project…**, on a hidden row's menu, forgets it for good. The
**Hidden** control disappears when there are no hidden projects.

## Resuming agent sessions after a restart

The app remembers the last agent session associated with each terminal,
whichever harness it was running. After relaunching Agents, opening a
restored terminal starts a fresh shell that prints one line naming the
harness and the remembered session title (or, for a session that never
titled itself, your last prompt) above its first prompt, and the app leaves
the harness's own resume command typed at that prompt, waiting:

```text
Last Claude Code session: Make the resume hint harness agnostic
❯ claude --resume 01a03bbc-0713-729c-a74b-b66f49ddeddd
```

Press Enter to resume it, or Ctrl-C to clear the line and use the shell for
something else. Agents never presses Enter for you: resuming starts the
harness, the first prompt you send it spends tokens, and restoring twenty
terminals should not start twenty agents unasked. The command is typed once
the shell reaches its first prompt — known from the first terminal title it
sets — or, for a shell that never sets one, a few seconds after the terminal
opens.

The heading is not typed: typed text reaches a shell as a paste, and a shell
with bracketed paste on (zsh, by default) would insert a `printf` line at
the prompt instead of running it. It is printed by the terminal's own spawn
instead — the restored terminal starts as `zsh -f -c '<print the heading>;
exec -l zsh'`, which becomes your login shell with its startup files and
Ghostty's shell integration exactly as a plain spawn would leave them. Two
consequences. The heading needs zsh as your login shell; under another
shell the resume command is still typed, with nothing printed above it.
And libghostty holds a terminal spawned with a command open after that
command exits, so typing `exit` in a restored terminal shows Ghostty's
"Process exited" line and closes on the next keypress, where a fresh
terminal closes at once.

How the app learns the session id depends on the harness:

| Harness     | Session announced by                            | Resume command         |
|-------------|-------------------------------------------------|------------------------|
| Claude Code | `hooks/agents-status.sh` (see below)            | `claude --resume <id>` |
| Codex CLI   | `hooks/agents-status.sh` (see below)            | `codex resume <id>`    |
| OMP         | `hooks/agents-omp.ts` extension                  | `omp --resume <id>`    |

If the harness was running under a non-default configuration home —
`CODEX_HOME` for Codex, `CLAUDE_CONFIG_DIR` for Claude Code — the typed
command carries it as a prefix, `CODEX_HOME=/path codex resume <id>`. That
directory is where the harness keeps the session; a fresh shell that doesn't
export the variable would otherwise look in the default location and find
nothing.

Claude Code and Codex announce their session through the same hook that
reports status (see "With the hook, for real agent state"). The hook
announces the session on every registered event, so even a partial
registration works — but the prompt preview comes only from
`UserPromptSubmit`, and a session that never calls a tool is only announced by
`SessionStart`, so register both if you want the banner to be reliable.

A harness running inside another harness's terminal — `codex exec` launched
from a Claude Code session to review its work, say — is not announced. The
terminal belongs to the outer agent, and the inner one's short-lived session
is not what you want back after a relaunch.

OMP reports its session and lifecycle through the extension described below.
Only OMP's default profile is covered. Named profiles do not yet provide enough
metadata for the app to construct a profile-qualified resume command.

### When no banner appears

The hook and the app are versioned together: the hook talks to the app over
its control socket in a form the app has to understand, so after pulling
this repository the installed app must be at least as new as the hook
(**Agents ▸ Check for Updates…**). The hook writes one line to
`~/Library/Logs/Agents/hook.log` whenever something is wrong — a pane spawned
by an older app, a refusal, no answer — and nothing when all is well. So an
empty log beside a missing banner means the hook never ran (check the
`hooks` entries in your harness settings), while a log full of
`no AGENTS_PANE_ID` means the app is older than the hook. The app itself logs
`Agents: session … is now resumable as …` when it records a session and
`typed resume command` when it types one; both are visible in Console.app
or with `log show --predicate 'process == "Agents"' --last 1h`. Setting
`AGENTS_HOOK_DEBUG=1` in the harness's environment logs every hook decision,
including the sessions it declined to announce.

## Agent dashboard

The right-side Agent Dashboard is a triage queue of sessions that need you.
"Blocked on you" appears first, followed by completed turns you have not yet
seen. Every card shows the session, project, workspace, and how long it has
been in that state. Repeated reports do not restart that duration. Selecting a
card opens its terminal.

Lifecycle phase and attention are separate. A run's phase is unknown, idle,
working, or blocked. Gold means a terminal turn event is still unseen, not
merely that the process is idle. A restored session starts with an unknown
phase until the harness reports again. No indicator still means that the app
has no reason to ask for your attention.

## Waiting indicators

Sessions show an indicator in the sidebar when their agent needs you:

- **Gold dot** — the agent reached a terminal turn event that you have not seen.
- **Red pulsing exclamation mark** — the agent is blocked on a permission
  prompt and is doing nothing until you answer. Blocked sessions are also
  counted on the Dock tile's badge, so they stay visible when the app isn't
  focused.

No indicator means the app has no attention signal; the agent may be working
or idle.

The two states differ by shape and motion, not only by colour: a session that
can wait indefinitely and one that is burning time deserve different urgency,
and a hue-only difference is no difference at all to anyone with colour-vision
deficiency. The pulse honours the system Reduce Motion setting — with it on,
the blocked glyph renders statically.

### With no setup at all

Any agent that emits an ordinary terminal desktop notification lights up a
session. Gemini CLI does this natively, and Claude Code can be asked to
(`preferredNotifChannel`). The app also listens for the terminal bell and for
OSC 9;4 progress reports.

Notification text is classified by keyword — wording about permission or
approval raises the red pulse, everything else raises the gold dot. That is
fuzzy by nature: the terminal protocol flattens the notification down to a
title and body, so the text is the only signal there is. It errs toward gold,
so unfamiliar wording costs you a less urgent indicator rather than a missed
permission prompt.

Selecting a session clears an indicator raised this way. Without a hook,
"you looked at it" is the only honest evidence that you've seen it.

### With the hook, for real agent state

Open **Settings → Harness Integrations** to install Claude Code, Codex, or OMP
reporting once per user configuration home. Choose a detected home or add a
custom directory, inspect the proposed changes, then Apply. Repair restores
missing or outdated integration entries; Remove detaches the selected home.
Codex still requires its native `/hooks` trust review.

The app installs bundled emitters independently of your checkout. Settings
shows configuration status separately from the last accepted harness report.
Start a fresh harness in a new Agents pane to check reporting. See
[Harness integration setup](design/harness-integration-setup.md) for ownership,
recovery, and compatibility details. The instructions below cover manual setup.

`hooks/agents-status.sh` sends each native hook event to the app's control
socket. The app maps those events to lifecycle phases and attention. The hook
is optional and needs `jq` plus `nc`, which macOS ships.

A live run that speaks this protocol takes authority over keyword
classification. Its red pulse survives selection and clears only on a matching
native resolution. A terminal event creates unseen-completion
attention; viewing the session acknowledges that attention without changing
the run's idle phase.

The script only speaks when it finds the app's environment — `AGENTS_APP`,
`AGENTS_CONTROL_SOCK`, `AGENTS_SESSION_ID`, `AGENTS_PANE_ID`, and
`AGENTS_PANE_GENERATION`, which this app stamps into every new pane. That makes it safe to register
globally, as below: in iTerm2, Terminal.app, or any other host, the hook
finds none of them and exits without doing anything.

It talks to the app directly rather than through the terminal, for a reason
worth knowing if you ever write your own: Ghostty throttles desktop
notifications app-wide — one per second, with identical content suppressed
for five — so a hook that writes OSC escapes to the pty loses any report
landing within a second of another one, and cannot tell, because the write
succeeded. The app still understands the `agents:status` and `agents:session`
OSC forms from other emitters; the bundled hook no longer uses them.

The same line announces the native session id, a short prompt preview when
available, and the harness configuration home. It also identifies one harness
process so the app can observe its real exit. There are no polling processes
or recurring timers. See [Harness adapters](design/harness-adapters.md) for the
wire contract and each harness's native-event gaps.

#### Claude Code

Wire it up in `settings.json` under Claude Code's config directory. That is
**`$CLAUDE_CONFIG_DIR`** if you have it set, and `~/.claude` only as the
default — if you've relocated your config, `~/.claude` may not exist at all:

```sh
"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
```

Use the **absolute** path to your clone; Claude Code does not expand `~`
here. If you already run another status script (an iTerm2 tab-colour hook,
say), add this one alongside it as a second entry in the same `hooks` array
rather than replacing it:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PostToolUseFailure": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ]
  }
}
```

`PermissionRequest` and permission notifications block the run. Tool and
prompt events show work. `Stop` settles a turn unless its native payload says
that work will continue. `SessionEnd` closes the native conversation; its
`clear` and `resume` reasons do not imply that the harness process exited. An
idle prompt is a notification, not proof that a turn completed. `SessionStart`
and `UserPromptSubmit` also make the resume hint reliable.

If you script this rather than editing by hand — an agent wiring itself up,
say — merge into the existing file and write the result **in place**.
`settings.json` is often a symlink into a dotfiles repo, and
`jq … > tmp && mv tmp settings.json` silently swaps the link for a plain
copy that the repo never sees again. This merges the hook into all nine
events, is safe to re-run, and writes through the link:

```sh
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
cmd=/path/to/agents/hooks/agents-status.sh
[ -f "$f" ] || echo '{}' > "$f"
jq --arg cmd "$cmd" '
  def ensure($ev; $new):
    .hooks[$ev] |= (
      . // [] |
      if any(.[]; (.hooks // []) | any((.command // "") | contains($cmd))) then .
      elif length > 0 then .[0].hooks += [{type: "command", command: $cmd}]
      else [$new + {hooks: [{type: "command", command: $cmd}]}]
      end);
  ensure("SessionStart"; {}) | ensure("SessionEnd"; {}) | ensure("Stop"; {})
  | ensure("Notification"; {}) | ensure("PermissionRequest"; {})
  | ensure("UserPromptSubmit"; {}) | ensure("PreToolUse"; {matcher: "*"})
  | ensure("PostToolUse"; {matcher: "*"})
  | ensure("PostToolUseFailure"; {matcher: "*"})
' "$f" > "$f.new" && cat "$f.new" > "$f" && rm "$f.new"
```

Where an event already has a hook group the command joins that group and
inherits its matcher; events with no group get the shapes shown above.

#### Codex

Codex CLI's lifecycle hooks share the event vocabulary and the JSON-on-stdin
payload, so the same script serves both. Its config lives at
`$CODEX_HOME/hooks.json` — again an env var first, with `~/.codex` as the
default — and takes the same shape:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Interrupt": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ]
  }
}
```

Two differences from Claude Code. Codex has no `Notification` or `PostToolUseFailure` event —
`PermissionRequest` is a first-class event and is what raises the red pulse.
And Codex requires you to explicitly trust a hook before it will run one; run
`/hooks` inside Codex to review and approve it. If you script the edit, write
`hooks.json` in place, for the same reason as above.

For a pane identified as Codex by its hooks, Agents also reads Codex's live
title status. Either blinking `Action Required` prefix raises a generic
permission blocker. A leading working spinner clears that generic blocker,
which covers the usual Codex `PermissionRequest` payload that has no request
ID. A blocker with a native request ID remains until the matching hook event
resolves it. Keep `activity` first in Codex's terminal-title settings (the
default in 0.153.4) to use this signal. If the title has no recognised status,
the hook state remains in effect.

If you run Codex through a wrapper that sets `CODEX_HOME` — a shell function
such as `cdk () { CODEX_HOME=~/.codex-work codex "$@"; }` — the hook file
belongs under that home, and the restore banner's command will carry the
same `CODEX_HOME=…` prefix, since that is where those sessions live.

The status hook exits 0 and stays silent on anything it doesn't recognise,
so it is harmless in terminals other than this app, and under agents that
send it events it has no opinion about.

#### OMP

Load the bundled extension when starting OMP, using an absolute path:

```sh
omp --extension /path/to/agents/hooks/agents-omp.ts
```

`-e` is the short form of `--extension`. For persistent discovery, place a
symlink to the file in the active profile's `extensions` directory, normally
`~/.omp/agent/extensions`. The extension reports only in TUI mode and only in
panes created by Agents. It sends native session, run, approval, question,
retry, and shutdown events in order. It uses no polling or model calls.

### Review tools

Run your preferred review tool in a separate session or split pane, alongside
whatever is producing the changes. Use New Session, Split Pane Right, or
Split Pane Down to open a terminal in the project or workspace directory.
Feedback and review completion follow the tool's own workflow.

## Opening a session from another tool

Another program on your machine can ask the app to open a session — a
dashboard's **Attach** button, say, that should land you in an Agents
terminal rather than Terminal.app. It sends one JSON line to the app's
control socket, the same socket the status hook reports over, and gets one
line back:

```json
{"cmd":"open-session","version":1,"cwd":"/Users/you/code/app","command":"claude-seeq attach 7ea9eb92","title":"Fix the parser"}
```

The reply is `{"ok":true}` once the session exists, or
`{"ok":false,"error":"…"}` saying what to fix. It never waits on the command
itself.

- `cwd` must be an absolute path to a directory that exists.
- `command` is one line, at most 4096 characters, with no control
  characters — no newlines, tabs, or escapes. It is typed into a shell, and
  any of those would make it run something other than the line you sent.
- `title` is optional: the session's name in the sidebar until the agent
  titles its terminal, as a fresh session's "Session N" would be.
- `version` is 1. Anything else is refused, so a sender written against a
  later form finds out at once rather than half-working.

The session goes where you would have put it by hand: into the deepest
project or workspace whose directory contains `cwd`. A hidden project that
contains it comes back to the sidebar first, as adding its directory would
bring it back. When nothing contains it, the app adds a project for it —
at its git or jj repository root, or at `cwd` itself outside any
repository — with the new session as its only one. Either way the new
session is selected and the app comes to the front.

The pane is an ordinary login shell started in `cwd`, with the same
environment as any other pane, so the status hook works for whatever runs
there. Once the shell reaches its prompt, the app types `command` and
presses Enter, just as the resume hint is typed after a relaunch, but this
time run, since running it is what you asked for. Typed rather than spawned
because only your own shell has your `PATH`, functions, and aliases, which
is usually where a tool like this lives. When the command exits (you
detach, say), the pane is back at that shell's prompt. Splits, and the pane
a relaunch brings back, start at the session's project or workspace root
like any other, and nothing is run again.

The socket lives at
`~/Library/Application Support/Agents/<bundle id>.control.<pid>.sock`:
`com.kirahowe.agents` for the release app, `com.kirahowe.agents.dev` for a
Debug build. The pid in the name keeps two running copies apart; the app
removes dead sockets when it starts, so normally the one match is the
running app. Inside an Agents pane, `$AGENTS_CONTROL_SOCK` already names it.

```sh
sock=$(ls "$HOME/Library/Application Support/Agents/"com.kirahowe.agents.control.*.sock | head -n 1)
printf '%s\n' '{"cmd":"open-session","version":1,"cwd":"/Users/you/code/app","command":"claude-seeq attach 7ea9eb92","title":"Fix the parser"}' \
  | nc -U -w 2 "$sock"
```

The socket is readable and writable only by you. It gives a program
nothing it couldn't already do itself: running a command as you.
