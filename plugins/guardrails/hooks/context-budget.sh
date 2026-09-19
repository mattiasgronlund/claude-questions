#!/usr/bin/env bash
# Tells the dispatcher to hand off once its context passes a budget — again as
# it keeps growing, and from inside a turn as well as between them.
#
# Every turn pays for its whole context again. CLAUDE.md already caps a *lane*
# at about 45 minutes for this reason, and the lanes obey it — 51 of them on
# 2026-09-05, median 17 minutes, none over 45. The dispatchers had no such cap
# and were the expensive half of the day: 1994 turns, 485M input tokens, 97% of
# it cache reads, while writing almost no code.
#
# The number is a dial, not a discovery. It started at 300k, dropped to 250k,
# and dropped to 200k on 2026-09-14: 35% of that week's spend was billed above
# 200k of context and only 16% above the 250k it then shipped with. It lives in
# `context-budget.default`, beside this script, and nowhere else — `statusline.sh`
# draws the same figure and reads that file too, rather than carrying its own
# copy. Two defaults kept in step by a comment is the exact drift this repo
# exists to end.
#
# ## The dial is not where the money is, and here is the measurement
#
# 2026-09-12 to 2026-09-20, 77 rcad dispatcher sessions, $828 between them.
# **23% of that was billed above the budget in force**, and turning the dial down
# reaches almost none of it, because the warning was already on time: 40 of the
# 41 sessions that crossed were warned, a median of 8.3k tokens past the
# threshold, which is 4% late. What the warning was not was repeated, or able to
# fire in the middle of a turn, or heeded:
#
#   13 points  billed after the warning had been delivered — a median of 13
#              further responses, and in one session 68 of them for $11.26. Only
#              15% of that tail touches a handoff, so it is not the cost of
#              obeying; it is the work carrying on at the most expensive context
#              the session will ever be at.
#    9 points  billed inside the turn that crossed the budget, before any Stop
#              could run. A turn here is long: 496 turns of two responses or more
#              that week, median growth 9.5k tokens, and the worst grew from 57k
#              to 246k across 105 responses without ever ending.
#    1 point   a session never warned at all.
#
# So: two changes, and the dial left alone.
#
# **A rung, not a sentinel.** The warning repeats every `step` of further growth.
# The session that ignores it is the expensive case by definition, and a sentinel
# meant that was the one session guaranteed never to hear from it again. 25k is
# the smallest step that is not a nag — on that week it is one extra warning in
# the median session past the budget and four in the worst, against $67 still
# ahead of the first repeat.
#
# **PostToolUse, not only the turn boundaries.** `tail -n 400 | jq` costs 14 ms
# on the largest transcript here (3.4 MB), so the check can afford to run on
# every tool call, and nothing cheaper reaches a turn that grows 188k tokens
# without returning. Between turns the advice is to hand off; inside one it is to
# finish the call and not start the next thing, because a hook cannot see whether
# a merge is half done.
#
# Never in a subagent — a lane is short by construction and has nowhere to hand
# off to.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
budget=${CLAUDE_CONTEXT_BUDGET:-}
if [ -z "$budget" ]; then
	budget=$(cat "$here/context-budget.default" 2>/dev/null)
	case "$budget" in '' | *[!0-9]*)
		echo "context-budget.sh: can't read a default from $here/context-budget.default" >&2
		exit 1
		;;
	esac
fi

step=${CLAUDE_CONTEXT_BUDGET_STEP:-25000}
case "$step" in '' | *[!0-9]* | 0) step=25000 ;; esac

payload=$(cat)

# A lane has an agent_id; it is not the session this is about.
[ -n "$(jq -r '.agent_id // empty' <<<"$payload")" ] && exit 0

session=$(jq -r '.session_id // "unknown"' <<<"$payload")
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")
event=$(jq -r '.hook_event_name // "Stop"' <<<"$payload")
[ -r "$transcript" ] || exit 0

# The last assistant turn's total input: fresh tokens plus everything re-read
# from cache. Only the tail is scanned — these files reach megabytes, and this
# now runs after every tool call.
tokens=$(tail -n 400 "$transcript" 2>/dev/null |
	jq -R 'fromjson? | select(.type == "assistant") | .message.usage |
		(.input_tokens // 0) + (.cache_creation_input_tokens // 0) +
		(.cache_read_input_tokens // 0)' 2>/dev/null | tail -n 1)

case "$tokens" in
'' | *[!0-9]*) exit 0 ;;
esac
[ "$tokens" -lt "$budget" ] && exit 0

# Which rung of the ladder this context is on: 0 at the budget, 1 a step above
# it, and so on. The file holds the highest rung already spoken for, so a session
# hears the warning once per step and not once per turn.
rung=$(((tokens - budget) / step))
state="${TMPDIR:-/tmp}/claude-context-budget-$session"
last=$(cat "$state" 2>/dev/null)
case "$last" in '' | *[!0-9]*) last=-1 ;; esac
[ "$rung" -le "$last" ] && exit 0
printf '%s\n' "$rung" >"$state"

pretty=$(printf "%'d" "$tokens")
cap=$(printf "%'d" "$budget")

# The first warning's line is word for word what it has always been, so a
# measurement over a window that spans this change can still count crossings; a
# repeat says so, and is countable on its own.
if [ "$last" -lt 0 ]; then
	headline="Context budget passed at $tokens tokens — handoff suggested."
	opening="Context is at $pretty input tokens, past the $cap budget. Raise it for a session with CLAUDE_CONTEXT_BUDGET."
else
	grown=$(printf "%'d" $((rung * step)))
	headline="Context budget still growing: $tokens tokens, $grown past it — handoff overdue."
	opening="Context is at $pretty input tokens — $grown past the $cap budget, and this is not the first time you have been told. Every response since the first warning has been billed at more than a fresh session would pay for the same call."
fi

if [ "$event" = "PostToolUse" ]; then
	read -r -d '' reason <<EOF || true
$opening

This is mid-turn, so the instruction is narrower than the usual one: finish the
call you are on — do not abandon a merge, a gate run or a half-written file —
and then hand off instead of starting the next thing. Say what it costs and keep
going only if the user has asked you to.
EOF
else
	read -r -d '' reason <<EOF || true
$opening

Every further turn pays this whole context again, and a dispatcher at this size
is re-reading far more than it is deciding. Hand off now rather than at the end
of the next unit:

1. Call the handoff skill. Say what the next session is for.
2. Finish or park what is in flight — commit it, or say in the doc that it is not committed.
3. Tell the user the handoff path and that a fresh session should pick it up.

Do this before starting new work, not after. If the user has explicitly asked
you to keep going in this session, say what it costs and then keep going.
EOF
fi

jq -n --arg r "$reason" --arg e "$event" --arg h "$headline" '{
	systemMessage: $h,
	additionalContext: $r,
	hookSpecificOutput: { hookEventName: $e, additionalContext: $r }
}'
exit 0
