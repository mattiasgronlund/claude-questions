#!/usr/bin/env bash
# Runs the context budget hook against its cases and reports any that came out
# wrong. The hook fires at most once per rung of a ladder, so every case that
# does not mean to climb one uses a session id of its own — a shared one would
# make the order of the cases matter.
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

# Firing again at the same size would nag every turn from the threshold on.
total=$((total + 1))
payload=$(jq -n --arg t "$work/big.jsonl" '{session_id:"repeat", transcript_path:$t, hook_event_name:"Stop"}')
first=$(TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook" <<<"$payload")
second=$(TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook" <<<"$payload")
if [ -z "$first" ] || [ -n "$second" ]; then
	echo "wanted the warning once per rung, got first='${first:0:20}' second='${second:0:20}'"
	failed=$((failed + 1))
fi

# A session that ignores the warning is the expensive one, and it used to be the
# one guaranteed never to hear again: 13% of a week's dispatcher spend was billed
# after a warning that was never repeated. A further step of growth says so again,
# and says it differently, so the two are countable apart in a transcript.
total=$((total + 1))
usage 260000 >"$work/rung1.jsonl"
usage 285000 >"$work/rung2.jsonl"
climb() {
	jq -n --arg t "$work/$1" '{session_id:"ladder", transcript_path:$t, hook_event_name:"Stop"}' |
		TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=250000 CLAUDE_CONTEXT_BUDGET_STEP=25000 "$hook"
}
one=$(climb rung1.jsonl | jq -r '.systemMessage')
again=$(climb rung1.jsonl)
two=$(climb rung2.jsonl | jq -r '.systemMessage')
if [ -z "$one" ] || [ -n "$again" ] || [ -z "$two" ] || [ "$one" = "$two" ]; then
	echo "wanted a first warning, silence inside the same step, then a different one a step up"
	echo "  got first='$one' repeat='${again:0:20}' stepped='$two'"
	failed=$((failed + 1))
fi

# The rung is counted from the first warning, not from the budget. A session that
# crosses deep inside a turn is first told well past the line — 72k past it, on
# the session that found this — and counting from the budget then puts the next
# rung a few thousand tokens away, so it is told again on the very next turn.
# Here: first warning at 290k against a 250k budget, then 300k, which is 40k and
# 50k past the budget (two different rungs, the old arithmetic) but only 10k
# apart (the same rung, which is the one that matters).
total=$((total + 1))
usage 290000 >"$work/deep1.jsonl"
usage 300000 >"$work/deep2.jsonl"
deep() {
	jq -n --arg t "$work/$1" '{session_id:"deep", transcript_path:$t, hook_event_name:"Stop"}' |
		TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=250000 CLAUDE_CONTEXT_BUDGET_STEP=25000 "$hook"
}
crossed=$(deep deep1.jsonl)
nagged=$(deep deep2.jsonl)
if [ -z "$crossed" ] || [ -n "$nagged" ]; then
	echo "wanted a step measured from the first warning, not from the budget:"
	echo "  first='${crossed:0:20}' 10k later='${nagged:0:20}'"
	failed=$((failed + 1))
fi

# A state file written by v0.3.2 holds the rung alone. Read as this version's two
# fields it says "first warned at 2 tokens, never warned" — which is how a session
# already warned twice got a *first* warning at 299,056. A live session outlives
# the version that warned it, so the old shape has to mean something: quiet now,
# and a repeat a full step later.
total=$((total + 1))
usage 260000 >"$work/upgrade.jsonl"
usage 286000 >"$work/upgrade2.jsonl"
printf '2\n' >"$work/claude-context-budget-upgraded"
upgraded() {
	jq -n --arg t "$work/$1" '{session_id:"upgraded", transcript_path:$t, hook_event_name:"Stop"}' |
		TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=250000 CLAUDE_CONTEXT_BUDGET_STEP=25000 "$hook"
}
quiet=$(upgraded upgrade.jsonl)
later=$(upgraded upgrade2.jsonl | jq -r '.systemMessage')
if [ -n "$quiet" ] || [ "${later#Context budget still growing}" = "$later" ]; then
	echo "wanted an old-format state file to stay quiet and then repeat, got"
	echo "  now='${quiet:0:40}' a step later='$later'"
	failed=$((failed + 1))
fi

# Nine points of that week were billed inside the turn that crossed the budget,
# where no Stop runs: the worst turn grew from 57k to 246k across 105 responses.
# So the check runs after a tool call too, with advice that fits being mid-turn.
total=$((total + 1))
midturn=$(jq -n --arg t "$work/big.jsonl" \
	'{session_id:"midturn", transcript_path:$t, hook_event_name:"PostToolUse"}' |
	TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=300000 "$hook")
if [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$midturn")" != "PostToolUse" ] ||
	! grep -q 'do not abandon a merge' <<<"$(jq -r '.additionalContext' <<<"$midturn")"; then
	echo "wanted a mid-turn warning addressed to PostToolUse, got: ${midturn:0:120}"
	failed=$((failed + 1))
fi

# The plugin declares the events it fires on, and a hook that answers correctly
# on an event nothing routes to it is a hook that never runs.
total=$((total + 1))
declared=$(jq -r '.hooks | to_entries[] | select(.value[].hooks[].command | contains("context-budget.sh")) | .key' \
	"$(dirname "$here")/hooks/hooks.json" | sort -u | tr '\n' ' ')
for event in PostToolUse Stop UserPromptSubmit; do
	case " $declared " in *" $event "*) ;;
	*)
		echo "hooks.json does not route $event to context-budget.sh (routes: $declared)"
		failed=$((failed + 1))
		break
		;;
	esac
done

# The shipped default, with nothing in the environment. 210k is over the 200k
# this ships with and under the 250k it shipped with before, so this case is the
# one that notices the default silently drifting back up.
total=$((total + 1))
usage 210000 >"$work/default.jsonl"
shipped=$(jq -n --arg t "$work/default.jsonl" '{session_id:"default", transcript_path:$t, hook_event_name:"Stop"}' |
	env -u CLAUDE_CONTEXT_BUDGET TMPDIR="$work" "$hook")
if [ -z "$shipped" ]; then
	echo "wanted the shipped default to warn at 210k tokens, got silence"
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
