#!/usr/bin/env bash
# Runs the context budget hook against its cases and reports any that came out
# wrong. The hook fires at most once per session, so every case uses a session
# id of its own — a shared one would make the order of the cases matter.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
hook=$(dirname "$here")/hooks/context-budget.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

usage() { printf '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":%s}}}\n' "$1"; }

usage 330000 >"$work/big.jsonl"
usage 90000 >"$work/small.jsonl"
printf '{"type":"user"}\nnot json at all\n' >>"$work/big.jsonl"
usage 330000 >>"$work/big.jsonl"

failed=0
total=0

# fires: name | transcript | extra payload fields | budget | want ("warn" or "quiet")
check() {
	local why=$1 file=$2 extra=$3 budget=$4 want=$5
	total=$((total + 1))
	local out
	out=$(jq -n --arg t "$work/$file" --argjson x "$extra" \
		'{session_id: ("s" + (now|tostring) + ($x|tostring|@base64)), transcript_path: $t, hook_event_name: "Stop"} + $x' |
		TMPDIR="$work" CLAUDE_CONTEXT_BUDGET="$budget" "$hook")
	local got=quiet
	[ -n "$out" ] && got=warn
	if [ "$got" != "$want" ]; then
		printf 'wanted %s, got %s: %s\n' "$want" "$got" "$why"
		failed=$((failed + 1))
	fi
}

check "over budget warns" big.jsonl '{}' 300000 warn
check "under budget stays quiet" small.jsonl '{}' 300000 quiet
check "a lane never hands off" big.jsonl '{"agent_id":"a123"}' 300000 quiet
check "a raised budget is not passed" big.jsonl '{}' 500000 quiet
check "a missing transcript is not an error" nowhere.jsonl '{}' 300000 quiet

# Firing twice in one session would nag every turn from the threshold on.
total=$((total + 1))
payload=$(jq -n --arg t "$work/big.jsonl" '{session_id:"repeat", transcript_path:$t, hook_event_name:"Stop"}')
first=$(TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook" <<<"$payload")
second=$(TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook" <<<"$payload")
if [ -z "$first" ] || [ -n "$second" ]; then
	echo "wanted the warning once per session, got first='${first:0:20}' second='${second:0:20}'"
	failed=$((failed + 1))
fi

# The shipped default, with nothing in the environment. 260k is over the 250k
# this ships with and under the 300k it started at, so this case is the one that
# notices the default silently drifting back.
total=$((total + 1))
usage 260000 >"$work/default.jsonl"
shipped=$(jq -n --arg t "$work/default.jsonl" '{session_id:"default", transcript_path:$t, hook_event_name:"Stop"}' |
	env -u CLAUDE_CONTEXT_BUDGET TMPDIR="$work" "$hook")
if [ -z "$shipped" ]; then
	echo "wanted the shipped default to warn at 260k tokens, got silence"
	failed=$((failed + 1))
fi

# The number in the message is the one the transcript reports, not a guess.
total=$((total + 1))
said=$(jq -n --arg t "$work/big.jsonl" '{session_id:"number", transcript_path:$t, hook_event_name:"Stop"}' |
	TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook" | jq -r '.systemMessage')
if ! grep -q '330000' <<<"$said"; then
	echo "wanted the reported token count in the message, got: $said"
	failed=$((failed + 1))
fi

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total context budget cases came out wrong"
	exit 1
fi

echo "$total context budget cases, all as expected"
