#!/bin/sh

fail() {
    printf 'Agents review submitter: %s\n' "$*" >&2
    exit 1
}

if [ ! -t 0 ]; then
    cat >/dev/null
fi
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || \
    fail "could not locate the app resources"
. "$resources/review-client.sh"
review_client_require || fail "$REVIEW_CLIENT_ERROR"

sock=${AGENTS_CONTROL_SOCK:-}
session=${AGENTS_SESSION_ID:-}
review=${AGENTS_REVIEW_ID:-}
[ -n "$sock" ] || fail "AGENTS_CONTROL_SOCK is missing"
[ -n "$session" ] || fail "AGENTS_SESSION_ID is missing"
[ -n "$review" ] || fail "AGENTS_REVIEW_ID is missing"

request=$(jq -cn --arg session "$session" --arg review "$review" \
    '{cmd:"review-submit", session:$session, review:$review}') || \
    fail "could not encode the review submission"
if review_client_send "$request"; then
    exit 0
fi
[ "$REVIEW_CLIENT_REFUSED" -eq 0 ] && fail "$REVIEW_CLIENT_ERROR"
fail "Agents.app refused the submission: $REVIEW_CLIENT_ERROR"
