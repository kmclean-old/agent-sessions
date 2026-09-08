#!/bin/sh

# Shared control-socket transport for the review launcher and flush hook.
# On failure, REVIEW_CLIENT_ERROR contains a message suitable for their own
# command-specific diagnostic prefix.
review_client_require() {
    command -v jq >/dev/null 2>&1 || {
        REVIEW_CLIENT_ERROR="jq is required"
        return 1
    }
    command -v nc >/dev/null 2>&1 || {
        REVIEW_CLIENT_ERROR="nc is required"
        return 1
    }
}

review_client_send() {
    request=$1
    REVIEW_CLIENT_REFUSED=0
    sock=${AGENTS_CONTROL_SOCK:-}
    [ -n "$sock" ] || {
        REVIEW_CLIENT_ERROR="AGENTS_CONTROL_SOCK is missing"
        return 1
    }
    [ -S "$sock" ] || {
        REVIEW_CLIENT_ERROR="the Agents.app control socket is unavailable at $sock"
        return 1
    }

    REVIEW_CLIENT_RESPONSE=$(printf '%s\n' "$request" | nc -U -w 5 "$sock")
    nc_status=$?
    [ "$nc_status" -eq 0 ] || {
        REVIEW_CLIENT_ERROR="the Agents.app control socket did not answer within 5 seconds"
        return 1
    }
    [ -n "$REVIEW_CLIENT_RESPONSE" ] || {
        REVIEW_CLIENT_ERROR="Agents.app closed the control socket without a response"
        return 1
    }
    if printf '%s' "$REVIEW_CLIENT_RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 0
    fi

    if printf '%s' "$REVIEW_CLIENT_RESPONSE" | jq -e '.ok == false' >/dev/null 2>&1; then
        REVIEW_CLIENT_REFUSED=1
    fi
    REVIEW_CLIENT_ERROR=$(printf '%s' "$REVIEW_CLIENT_RESPONSE" | \
        jq -r '.error // "invalid response from Agents.app"' 2>/dev/null) || \
        REVIEW_CLIENT_ERROR="invalid response from Agents.app"
    return 1
}
