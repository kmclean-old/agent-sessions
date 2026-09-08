#!/bin/sh

fail() {
    printf 'Agents review launcher: %s\n' "$*" >&2
    exit 1
}

resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || \
    fail "could not locate the app resources"
. "$resources/review-client.sh"
review_client_require || fail "$REVIEW_CLIENT_ERROR"

sock=${AGENTS_CONTROL_SOCK:-}
session=${AGENTS_SESSION_ID:-}
pane=${AGENTS_PANE_ID:-}
[ -n "$sock" ] || fail "AGENTS_CONTROL_SOCK is missing; run this from an Agents.app session"
[ -n "$session" ] || fail "AGENTS_SESSION_ID is missing; run this from an Agents.app session"
[ -n "$pane" ] || fail "AGENTS_PANE_ID is missing; update Agents.app and open a new session"

for arg in "$@"; do
    case "$arg" in
        -o|-[o]?*|--output|--output=*|--post-flush-command|--post-flush-command=*)
            fail "$arg is managed by Agents.app and cannot be passed explicitly"
            ;;
    esac
done

if [ -n "${REVDIFF_CONFIG:-}" ] && [ -f "$REVDIFF_CONFIG" ]; then
    set -- "--config=$REVDIFF_CONFIG" "$@"
fi

revdiff=$(command -v revdiff 2>/dev/null) || fail "revdiff was not found in PATH"
case "$revdiff" in
    /*) ;;
    *) revdiff=$(pwd)/$revdiff ;;
esac

request=$(
    jq -cn \
        --arg command "$revdiff" \
        --arg cwd "$(pwd)" \
        --arg session "$session" \
        --arg pane "$pane" \
        '{cmd:"review-open", command:$command, args:$ARGS.positional,
          cwd:$cwd, session:$session, pane:$pane,
          env:($ENV | with_entries(select(
            (.key == "PATH") or (.key == "LANG") or (.key == "LC_ALL") or
            (.key == "LC_CTYPE") or (.key == "XDG_CONFIG_HOME") or
            (.key == "XDG_DATA_HOME") or (.key == "XDG_CACHE_HOME") or
            (.key == "GIT_CONFIG_GLOBAL") or (.key == "HGRCPATH") or
            (.key == "EDITOR") or (.key == "VISUAL") or
            (.key | startswith("REVDIFF_")) or (.key | startswith("JJ_"))
          )))}' --args -- "$@"
) || fail "could not encode the review request"

if review_client_send "$request"; then
    printf '%s\n' 'Review opened. End this turn; submitted feedback will arrive in the originating session. Do not wait or poll for this review.'
    exit 0
fi

case "$REVIEW_CLIENT_ERROR" in
    *"unknown cmd"*)
        fail "Agents.app does not support detached reviews ($REVIEW_CLIENT_ERROR); update or rebuild the app"
        ;;
    *)
        [ "$REVIEW_CLIENT_REFUSED" -eq 0 ] && fail "$REVIEW_CLIENT_ERROR"
        fail "Agents.app refused the review: $REVIEW_CLIENT_ERROR"
        ;;
esac
