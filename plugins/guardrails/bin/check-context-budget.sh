#!/usr/bin/env bash
# Runs the context budget hook against its cases and reports any that came out
# wrong. The hook fires at most once per rung of a ladder, so every case that
# does not mean to climb one uses a session id of its own — a shared one would
# make the order of the cases matter.
#
# The cases run in the C locale, which is what CI's runner has. Under this
# machine's locale they passed for six days while the runner failed them:
# `printf "%'d"` groups thousands only where the locale has a separator, and a
# case wanting "26,000" read "26000" there. That is rcad §173's shape — a check
# answering a property of its environment — so the environment is fixed here.
export LC_ALL=C
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
check "a raised budget is not passed" big.jsonl '{}' 500000 quiet
check "a missing transcript is not an error" nowhere.jsonl '{}' 300000 quiet

# A lane is handed its dispatcher's transcript, not its own. Every hook that
# fires inside a subagent gets the *session's* `transcript_path`; the lane's
# file is `<session>/subagents/agent-<id>.jsonl` beside it, one level deeper for
# a workflow's agents, and under another project directory altogether when the
# session entered a worktree after it started. These cases used to put the
# lane's own figure in `transcript_path` — a payload Claude Code never sends —
# and passed for five days while every lane was measured on its dispatcher.
# `lane` lays out both files and prints the payload a lane really receives.
#
#     lane <session> <agent> <lane tokens> <dispatcher tokens> [<subdir>] [<project>]
lane() {
	local session=$1 agent=$2 sub=${5:+$5/} project=${6:-repo}
	mkdir -p "$work/projects/repo" "$work/projects/$project/$session/subagents/$sub"
	usage "$4" >"$work/projects/repo/$session.jsonl"
	usage "$3" >"$work/projects/$project/$session/subagents/${sub}agent-$agent.jsonl"
	jq -n --arg s "$session" --arg a "$agent" --arg t "$work/projects/repo/$session.jsonl" \
		'{session_id:$s, agent_id:$a, transcript_path:$t, hook_event_name:"PostToolUse"}'
}
lane_hook() { env -u CLAUDE_CONTEXT_BUDGET -u CLAUDE_LANE_BUDGET TMPDIR="$work" "$hook"; }

# A lane used to be exempt outright. It is not short in tokens — 134 rcad lanes
# over 2026-09-12..21 reached a median peak of 134k and a worst of 335k, and
# 37.7% of their $433 was billed at or above the 150k this now ships. What a
# lane cannot do is hand off, so it is told to finish the call, commit and
# report — unless its brief told it to run on — and the headline says "Lane
# budget" so the two kinds of warning stay countable apart in a transcript. The
# figure is the lane's: 330k, under a dispatcher at 90k that is past nothing.
total=$((total + 1))
warned=$(lane lane-warns a123 330000 90000 | lane_hook)
said=$(jq -r '.systemMessage' <<<"$warned")
body=$(jq -r '.additionalContext' <<<"$warned")
if [ "${said#Lane budget passed at 330000 tokens}" = "$said" ] ||
	[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$warned")" != "PostToolUse" ] ||
	! grep -q 'Finish the call you are on' <<<"$body" ||
	! grep -q 'Commit what is done' <<<"$body" ||
	! grep -q 'If your brief explicitly told you to run past this point' <<<"$body" ||
	grep -q 'Call the handoff skill' <<<"$body"; then
	echo "wanted a lane told its own 330k, to finish the call, commit and report unless"
	echo "its brief says to run on, and never sent to the handoff skill, got"
	echo "  headline='$said'"
	echo "  body='${body:0:200}'"
	failed=$((failed + 1))
fi

# The other half of the same fault: a dispatcher past the lane dial is not a lane
# past it. Of the 76 lanes warned from 2026-09-20 to 25, 51 never reached 150k
# themselves, and two stopped with nothing done on the strength of it.
total=$((total + 1))
dispatcher_only=$(lane lane-small a124 50000 330000 | lane_hook)
if [ -n "$dispatcher_only" ]; then
	echo "wanted a lane at 50k under a dispatcher at 330k to stay quiet, got: ${dispatcher_only:0:80}"
	failed=$((failed + 1))
fi

total=$((total + 1))
in_workflow=$(lane lane-workflow a125 160000 90000 workflows/wf_0123abcd-ef0 | lane_hook)
if [ -z "$in_workflow" ]; then
	echo "wanted a workflow's lane at 160k, under subagents/workflows/<run>/, to warn, got silence"
	failed=$((failed + 1))
fi

# rcad session 0e21fcb4 on 2026-09-25: its own transcript stayed under the hub's
# project directory, and its lanes were written under the worktree's.
total=$((total + 1))
moved=$(lane lane-moved a126 160000 90000 "" worktree | lane_hook)
if [ -z "$moved" ]; then
	echo "wanted a lane at 160k found under another project directory than its session, got silence"
	failed=$((failed + 1))
fi

# A lane whose transcript cannot be found must not be measured on the
# dispatcher's instead — that fallback is the fault, and it looked like a
# working hook for five days. It fails out loud, so a change in where Claude
# Code keeps a subagent's transcript is an error rather than a silence.
total=$((total + 1))
usage 330000 >"$work/projects/repo/lane-lost.jsonl"
lost=$(jq -n --arg t "$work/projects/repo/lane-lost.jsonl" \
	'{session_id:"lane-lost", agent_id:"a127", transcript_path:$t, hook_event_name:"PostToolUse"}' |
	lane_hook 2>"$work/lost.err")
lost_status=$?
if [ "$lost_status" -eq 0 ] || [ -n "$lost" ] || ! grep -q 'a127' "$work/lost.err"; then
	echo "wanted a lane with no transcript to fail naming it, not to read the dispatcher's, got"
	echo "  status=$lost_status stdout='${lost:0:40}' stderr='$(head -c 120 "$work/lost.err")'"
	failed=$((failed + 1))
fi

# The lane dial is its own, and reading the session's would exempt every lane
# below 200k — which is 87% of them, and the reason this is a separate figure.
# 160k is over the 150k shipped and under the session's 200k.
total=$((total + 1))
between=$(lane lane-dial b456 160000 90000 | lane_hook)
usage 160000 >"$work/lane-mid.jsonl"
session_quiet=$(jq -n --arg t "$work/lane-mid.jsonl" \
	'{session_id:"lane-dial-session", transcript_path:$t, hook_event_name:"Stop"}' | lane_hook)
if [ -z "$between" ] || [ -n "$session_quiet" ]; then
	echo "wanted 160k to warn a lane and not a session, got"
	echo "  lane='${between:0:40}' session='${session_quiet:0:40}'"
	failed=$((failed + 1))
fi

# CLAUDE_LANE_BUDGET raises it; CLAUDE_CONTEXT_BUDGET is not the lane's dial and
# must not silence one.
total=$((total + 1))
raised=$(lane lane-raised c789 330000 90000 |
	env -u CLAUDE_CONTEXT_BUDGET TMPDIR="$work" CLAUDE_LANE_BUDGET=500000 "$hook")
wrong_dial=$(lane lane-wrong-dial d012 330000 90000 |
	env -u CLAUDE_LANE_BUDGET TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=500000 "$hook")
if [ -n "$raised" ] || [ -z "$wrong_dial" ]; then
	echo "wanted CLAUDE_LANE_BUDGET to raise the lane dial and CLAUDE_CONTEXT_BUDGET not to, got"
	echo "  raised='${raised:0:40}' wrong_dial='${wrong_dial:0:40}'"
	failed=$((failed + 1))
fi

# Several lanes share one session_id. Keyed on that alone, the first lane's rung
# silences every other lane of the same dispatch — the failure this file's
# opening comment warns about for cases, happening in production.
total=$((total + 1))
one_lane=$(lane shared first 330000 90000 | lane_hook)
other_lane=$(lane shared second 330000 90000 | lane_hook)
if [ -z "$one_lane" ] || [ -z "$other_lane" ]; then
	echo "wanted each lane of a session to climb its own ladder, got"
	echo "  first='${one_lane:0:40}' second='${other_lane:0:40}'"
	failed=$((failed + 1))
fi

# The shipped lane default, with nothing in the environment. 155k is over the
# 150k this ships with and under every figure considered above it, so this is
# the case that notices the default drifting.
total=$((total + 1))
lane_shipped=$(lane lane-default f678 155000 90000 | lane_hook)
if [ -z "$lane_shipped" ]; then
	echo "wanted the shipped lane default to warn at 155k tokens, got silence"
	failed=$((failed + 1))
fi

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

# Fixing the reader did not undo what the bad reader had already written: v0.3.3
# persisted the misread rung as a baseline, in the new two-field format, so v0.3.4
# trusted it and told this hook's author it was "319,479 more than when you were
# first told". A baseline under the budget was never written by this script, which
# is the invariant the check rests on.
total=$((total + 1))
usage 325010 >"$work/corrupt1.jsonl"
usage 351010 >"$work/corrupt2.jsonl"
printf '3 11\n' >"$work/claude-context-budget-corrupt"
corrupt() {
	jq -n --arg t "$work/$1" '{session_id:"corrupt", transcript_path:$t, hook_event_name:"Stop"}' |
		TMPDIR="$work" CLAUDE_CONTEXT_BUDGET=250000 CLAUDE_CONTEXT_BUDGET_STEP=25000 "$hook"
}
hushed=$(corrupt corrupt1.jsonl)
sane=$(corrupt corrupt2.jsonl | jq -r '.systemMessage')
if [ -n "$hushed" ] || ! grep -q '26,000 more since the first warning' <<<"$sane"; then
	echo "wanted a baseline under the budget to be rejected, then a sane repeat, got"
	echo "  now='${hushed:0:40}' a step later='$sane'"
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
