#!/bin/sh

directory=$1
AGENTS_CONTROL_SOCK=$2
export AGENTS_CONTROL_SOCK
revdiff=$3
[ -n "$directory" ] && [ -n "$revdiff" ] || {
    printf 'usage: review-run.sh <directory> <socket> <revdiff> [args ...]\n' >&2
    exit 2
}
shift 3

submit=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/review-submit.sh
quoted_submit=$(printf '%s' "$submit" | sed "s/'/'\\\\''/g")
quoted_submit="'$quoted_submit'"

finish() {
    printf '%s\n' "$1" >"$directory/status"
    exit "$1"
}
trap 'finish 130' INT
trap 'finish 143' TERM
trap 'finish 129' HUP
REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true "$revdiff" "$@" \
    "--output=$directory/annotations.md" \
    "--post-flush-command=$quoted_submit" \
    2>"$directory/stderr"
finish "$?"
