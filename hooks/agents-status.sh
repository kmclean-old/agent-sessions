#!/usr/bin/env bash
# Sends Claude Code and Codex lifecycle hooks to the Agents control socket.
# New panes provide AGENTS_PANE_GENERATION and receive version 1
# `harness-event` reports. A run is the nearest harness ancestor's exact PID
# plus its OS start stamp. Native conversation, turn, request, outcome, and
# interrupt fields are forwarded when the hook supplies them.
#
# Older panes have no generation. They keep the `session-event` behavior used
# by older Agents builds: hook names map to clear, blocked, or your-turn
# attention and carry resume metadata when available.
#
# The process walk suppresses a harness nested inside another harness. Claude
# payloads with agent_id are native subagents and are also suppressed. If a new
# pane's hook cannot identify the actual harness process, it sends the legacy
# attention report without a guessed PID.
#
# The socket exchange is synchronous and bounded to two idle seconds. This
# script has no polling or persistent state. The app maps native event names to
# lifecycle phases and observes the reported PID for process exit. Diagnostics
# go to ~/Library/Logs/Agents/hook.log; AGENTS_HOOK_DEBUG=1 adds decisions that
# normally stay quiet. jq and macOS nc are required.

# Stdin is drained FIRST, before any early exit: Claude Code writes the hook
# payload into this process's stdin, and exiting before reading it leaves
# the parent writing into a pipe with no reader — an EPIPE on every tool
# call in every terminal that isn't this app.
input=$(cat)

[ -n "${AGENTS_APP:-}" ] || exit 0

log_dir="$HOME/Library/Logs/Agents"
# One line, timestamped, unless it repeats the previous line's message.
log() {
    mkdir -p "$log_dir" 2>/dev/null || return 0
    local msg="$*" last=""
    [ -f "$log_dir/hook.log" ] && last=$(tail -n 1 "$log_dir/hook.log" 2>/dev/null | cut -d' ' -f2-)
    [ "$last" = "$msg" ] && return 0
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$msg" >> "$log_dir/hook.log"
}
debug() { [ -n "${AGENTS_HOOK_DEBUG:-}" ] && log "debug: $*"; return 0; }

sock="${AGENTS_CONTROL_SOCK:-}"
session="${AGENTS_SESSION_ID:-}"
pane="${AGENTS_PANE_ID:-}"
if [ -z "$pane" ]; then
    # AGENTS_APP without AGENTS_PANE_ID: an Agents build older than this
    # script's protocol spawned the pane. Nothing to talk to — the app would
    # refuse the verb — but that is the one silence worth explaining.
    log "no AGENTS_PANE_ID in this pane: the Agents app that spawned it predates the socket hook (update the app)"
    exit 0
fi
{ [ -n "$sock" ] && [ -n "$session" ]; } || exit 0
[ -S "$sock" ] || { log "no control socket at $sock (app quit?)"; exit 0; }

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
ntype=$(printf '%s' "$input" | jq -r '.notification_type // empty')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$event" ] || exit 0

# The harness whose child we are. The NEAREST matching ancestor names the
# harness, so the real chain — bash(hook) -> /opt/homebrew/bin/claude ->
# -/bin/zsh -> login -> Agents — resolves at the second hop; a further
# match above it means this harness is nested inside another's pane (see
# the header). `ps -o comm=` on macOS prints the executable's path (a login
# shell prints "-/bin/zsh"); the basename is what gets matched.
AGENT=""
AGENT_PID=""
NESTED_IN=""
find_agent() {
    local pid=$$ c base
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
        c=$(ps -o comm= -p "$pid" 2>/dev/null)
        base=${c##*/}
        case "$base" in
            claude*|codex*)
                if [ -z "$AGENT" ]; then
                    AGENT=${base%%[!a-z]*}
                    AGENT_PID=$pid
                else
                    NESTED_IN=${base%%[!a-z]*}
                    return
                fi
                ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
}
find_agent
if [ -n "$NESTED_IN" ]; then
    debug "$event: $AGENT session $sid is nested inside $NESTED_IN; not reported"
    exit 0
fi
# Claude Code stamps CLAUDECODE=1 into every child's environment, so its
# presence is still good evidence when the walk came up empty (Codex has no
# equivalent marker). With neither, the line goes out without a session.
if [ -z "$AGENT" ] && [ -n "${CLAUDECODE:-}" ]; then
    AGENT="claude"
fi

# The versioned lifecycle protocol needs an OS process identity. A native
# conversation id is deliberately not used as the run id because a resumed
# conversation starts a new harness process. Hooks from that process share the
# ancestor PID and its kernel-reported start stamp. If the process walk did not
# find the harness, retain the legacy report below rather than attaching made-up
# process data to a lifecycle event.
generation="${AGENTS_PANE_GENERATION:-}"
if [ -n "$generation" ] && [ -n "$AGENT_PID" ]; then
    # Claude includes agent_id for subagent hooks. They belong to the root
    # harness process but do not describe its lifecycle.
    if [ "$AGENT" = "claude" ]; then
        native_agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
        [ -z "$native_agent_id" ] || { debug "$event: Claude subagent $native_agent_id not reported"; exit 0; }
    fi

    start_stamp=$(ps -o lstart= -p "$AGENT_PID" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$start_stamp" ] || { debug "$event: no process start stamp for $AGENT_PID; using legacy report"; generation=""; }
fi

if [ -n "$generation" ] && [ -n "$AGENT_PID" ]; then
    run_id="$AGENT_PID:$start_stamp"
    case "$AGENT" in
        claude) home="${CLAUDE_CONFIG_DIR:-}" ;;
        codex)  home="${CODEX_HOME:-}" ;;
        *)      exit 0 ;;
    esac

    body=$(printf '%s' "$input" | jq -c \
        --arg session "$session" --arg pane "$pane" --arg generation "$generation" \
        --arg agent "$AGENT" --arg run_id "$run_id" --argjson pid "$AGENT_PID" --arg home "$home" '
        {cmd: "harness-event", version: 1, session: $session, pane: $pane,
         generation: $generation, agent: $agent, run_id: $run_id, pid: $pid,
         event: .hook_event_name}
        + (if (.session_id | type) == "string" and .session_id != "" then {agent_session_id: .session_id} else {} end)
        + (if $home != "" then {agent_home: $home} else {} end)
        + ((if (.prompt | type) == "string" then .prompt elif (.query | type) == "string" then .query else null end) as $q
           | if $q != null then {prompt: $q[0:200]} else {} end)
        + (if (.turn_id | type) == "string" or (.turn_id | type) == "number" then {turn_id: (.turn_id | tostring)} else {} end)
        + ((.tool_use_id // .toolCallId // .tool_call_id // null) as $r
           | if ($r | type) == "string" and $r != "" then {request_id: $r} else {} end)
        + ((.tool_name // .toolName // null) as $t
           | if ($t | type) == "string" and $t != "" then {tool_name: $t} else {} end)
        + (if (.notification_type | type) == "string" and .notification_type != "" then {notification_type: .notification_type} else {} end)
        + ((.source // .reason // null) as $s
           | if ($s | type) == "string" and $s != "" then {source: $s} else {} end)
        + (if (.message | type) == "string" and .message != "" then {message: .message} else {} end)
        + (if has("outcome") then {outcome: .outcome} else {} end)
        + (if (.will_continue | type) == "boolean" then {will_continue: .will_continue} else {} end)
        + (if (.is_interrupt | type) == "boolean" then {is_interrupt: .is_interrupt} else {} end)
        ' 2>/dev/null) || exit 0
    [ -n "$body" ] || exit 0

    reply=$(printf '%s\n' "$body" | nc -U -w 2 "$sock" 2>/dev/null)
    case "$reply" in
        *'"ok":true'*) debug "$event: $AGENT run $run_id -> ok" ;;
        "")            log "$event: no reply from the app at $sock" ;;
        *)             log "$event: refused: $reply" ;;
    esac
    exit 0
fi

# The harness's configuration home, when its environment names one. Only
# the harness's OWN variable: a CLAUDE_CONFIG_DIR inherited by a Codex
# session says nothing about where Codex keeps its sessions.
home=""
case "$AGENT" in
    claude) home="${CLAUDE_CONFIG_DIR:-}" ;;
    codex)  home="${CODEX_HOME:-}" ;;
esac

status=""
case "$event" in
    SessionStart|UserPromptSubmit|PreToolUse|PostToolUse) status="clear" ;;
    Stop)              status="your-turn" ;;
    PermissionRequest) status="blocked" ;;
    Notification)
        case "$ntype" in
            permission_prompt) status="blocked" ;;
            idle_prompt)       status="your-turn" ;;
        esac
        ;;
esac

# `-c` keeps the whole request on one line, which is the framing the app's
# reader expects. The prompt (.prompt, or .query as a fallback field name)
# is sliced to its first 200 codepoints: the app caps it there anyway, and a
# pasted novel has no business in a banner heading.
body=$(printf '%s' "$input" | jq -c \
    --arg session "$session" --arg pane "$pane" --arg event "$event" \
    --arg status "$status" --arg agent "$AGENT" --arg sid "$sid" --arg home "$home" '
    {cmd: "session-event", session: $session, pane: $pane, event: $event}
    + (if $status != "" then {status: $status} else {} end)
    + (if $agent != "" and $sid != "" then {agent: $agent, agent_session_id: $sid} else {} end)
    + (if $agent != "" and $sid != "" and $home != "" then {agent_home: $home} else {} end)
    + ((if (.prompt | type) == "string" then .prompt
        elif (.query | type) == "string" then .query
        else null end) as $q
       | if $q != null then {prompt: $q[0:200]} else {} end)
    ' 2>/dev/null) || exit 0
[ -n "$body" ] || exit 0

# -w 2: give up after two idle seconds rather than stall the agent behind an
# app that stopped answering. The reply is not needed here beyond
# diagnostics; the connection staying open until the app has applied the
# event is.
reply=$(printf '%s\n' "$body" | nc -U -w 2 "$sock" 2>/dev/null)
case "$reply" in
    *'"ok":true'*) debug "$event: ${AGENT:-no-agent} $sid -> ok" ;;
    "")            log "$event: no reply from the app at $sock" ;;
    *)             log "$event: refused: $reply" ;;
esac

exit 0
