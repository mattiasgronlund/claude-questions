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
# **A rung, not a sentinel.** The warning repeats every `step` of growth **past
# the first warning**. The session that ignores it is the expensive case by
# definition, and a sentinel meant that was the one session guaranteed never to
# hear from it again. 25k is the smallest step that is not a nag — on that week it
# is one extra warning in the median session past the budget and four in the
# worst, against $67 still ahead of the first repeat. Counting rungs from the
# budget instead is what shipped first and what the comment beside the arithmetic
# below says not to do.
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

# Which rung of the ladder this context is on, counted from **where the first
# warning landed** rather than from the budget, so the second warning always
# comes a whole step after the first. The file holds that first figure and the
# highest rung already spoken for.
#
# Counting from the budget was the first version and it was wrong within two
# turns of shipping. The session that crosses deep inside a turn — the case the
# PostToolUse arm exists for — is first told at, say, 72k past the line, which is
# already rung 2, and is then told again 3k later on reaching rung 3. Measured on
# the session that wrote this: warned at 272,565 and again at 277,124, two turns
# running. A ladder anchored to where you started climbing cannot do that.
#
# **Both fields or neither.** v0.3.2 wrote the rung alone, and reading that file
# with this version's `read first last` takes the rung as the figure first warned
# at — a baseline of 2 or 3 tokens, and a `last` of nothing, which says "never
# warned". It said exactly that to the session that wrote v0.3.3, one version
# later and at 299,056 tokens: a **first** warning, offering to raise a budget it
# had already been told about twice. A live session's state file outlives the
# version that wrote it, so a format that changes has to say what the old one
# means. Here: the figure is unrecoverable, so the ladder restarts from now and
# the next warning is a repeat, which is the one thing that is certainly true.
#
# **A baseline under the budget is not a baseline.** The only figure this script
# ever writes there is one it has just compared against the budget and found
# greater, so anything smaller was written by something else — v0.3.3 reading a
# v0.3.2 file, and then persisting the 3 it had misread, which is the shape that
# reached `319,479 more than when you were first told`. Fixing the reader was not
# enough because the bad figure was already on disk, wearing the new format. The
# invariant is cheap to state and the check is the same branch as the upgrade.
state="${TMPDIR:-/tmp}/claude-context-budget-$session"
read -r first last <<<"$(cat "$state" 2>/dev/null)"
case "${first:-}" in '' | *[!0-9]*) first= ;; esac
case "${last:-}" in '' | *[!0-9]*) last= ;; esac
if [ -z "$first" ] || [ -z "$last" ] || [ "$first" -lt "$budget" ]; then
	warned_before=$first
	first=$tokens
	last=-1
	[ -n "$warned_before" ] && last=0
fi
rung=$(((tokens - first) / step))

# Written before the quiet exit and not after it, because the quiet exit is the
# one that has something to record: an upgraded state file decides its baseline
# on a call that says nothing, and a write that happens only when the hook speaks
# would throw that away and re-decide it, identically, for ever.
keep=$last
[ "$rung" -gt "$last" ] && keep=$rung
printf '%s %s\n' "$first" "$keep" >"$state"
[ "$rung" -le "$last" ] && exit 0

pretty=$(printf "%'d" "$tokens")
cap=$(printf "%'d" "$budget")

# The first warning's line is word for word what it has always been, so a
# measurement over a window that spans this change can still count crossings; a
# repeat says so, and is countable on its own.
if [ "$last" -lt 0 ]; then
	headline="Context budget passed at $tokens tokens — handoff suggested."
	opening="Context is at $pretty input tokens, past the $cap budget. Raise it for a session with CLAUDE_CONTEXT_BUDGET."
else
	grown=$(printf "%'d" $((tokens - first)))
	headline="Context budget still growing: $tokens tokens, $grown more since the first warning — handoff overdue."
	opening="Context is at $pretty input tokens, past the $cap budget — $grown more than when you were first told, and that first time was not heeded. Every response since has been billed at more than a fresh session would pay for the same call."
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
