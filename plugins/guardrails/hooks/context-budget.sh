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
# ## A lane hears a different number, and is told to do a different thing
#
# This exited early on any `agent_id` until 2026-09-20, saying a lane "is short
# by construction and has nowhere to hand off to". The second half was wrong: a
# lane's handoff is its report — commit, say what is left, stop — which every
# brief already asks for and nothing enforced. The first half was never
# measured, and is false. Over 2026-09-12 to 2026-09-21, 134 rcad lanes spent
# $433.55 between them, and their context reached a median peak of 134k, a p90
# of 221k and a worst of 335k. A lane is short in *minutes*, which is what the
# 45-minute rule caps; minutes are not tokens.
#
# The dial is picked the way the session dial was picked — the line where about
# a third of the spend is billed above it. For lanes that is **150k**: $163 of
# the $433, 37.7%, against 31.0% at 160k and 43.7% at 140k. It warns 40% of
# lanes, a median of two rungs each and eight in the worst, and the 25k step is
# the session's, for the session's reason.
#
# It is deliberately *not* the session's 200k, which would reach 12.9% — near
# enough to nothing to not be worth a separate dial. It lives in
# `lane-budget.default`, beside this script and nowhere else, for the same
# reason the session figure does.
#
# **Re-measure it rather than believing this paragraph**, which is dated the day
# it was written and goes stale on the next dispatch. In rcad,
# `just spend <since> <until> ceiling subagents` prices a cap over lanes alone —
# the `subagents` argument is a path filter, and a lane transcript is the only
# kind with that in its path. It reported $25.77, 5.9% of lane spend, saved at a
# 150k cap against $5.74 and 1.3% at 200k, which is the same conclusion in the
# other currency: 200k is not worth a dial of its own. rcad's `docs/decisions.md`
# §170 carries the rest, including the per-lane distribution this was chosen on.
#
# What a lane must not be told is to hand off: there is no next session to pick
# it up, and it cannot raise its own budget. It is told to commit, report the
# remainder and stop, which is the thing it can actually do. The headline says
# "Lane budget" rather than "Context budget" so the two stay countable apart in
# a transcript.
#
# ## Where a lane's own figure lives, which is not where it is pointed
#
# Every hook that fires inside a subagent is given the **session's**
# `transcript_path`. The lane's file is `<session>/subagents/agent-<id>.jsonl`
# beside it — under `subagents/workflows/<run>/` for a workflow's agents — and no
# field of a PostToolUse payload names it: `agent_transcript_path` exists only on
# SubagentStop, in claude 2.1.281. v0.3.6 read the path it was handed, so from
# 2026-09-20 every lane was told its dispatcher's size as its own. In 58 of 58
# lanes warned over 2026-09-22..25 the figure matched a row of the dispatcher's
# transcript and no row of the lane's; of 459 lanes in that window, 51 were warned
# without reaching 150k and 168 passed it unwarned. Two lanes stopped with their
# work undone, and the explanation that went round — a lane "starts at 173k before
# doing anything" — was the dispatcher's growth, read off lanes that start at
# 45–60k.
#
# The file is looked for under every project directory, not only the session's: a
# session that enters a worktree after it starts keeps its own transcript where it
# began and writes its lanes under the worktree's (rcad session 0e21fcb4,
# 2026-09-25). A lane whose file cannot be found fails the hook out loud. Falling
# back to the session's transcript is the fault itself, and staying quiet would
# turn the lane arm off without anyone noticing. It cannot misfire on a lane's
# first call: a probe lane found its own file on disk *during* that call, already
# ending in the assistant turn that made it.
#
# A lane never fires `Stop` either — it fires SubagentStop, which this plugin does
# not route — so v0.3.6's lane Stop arm never ran: 0 of those 76 lanes saw its
# text, and the one sentence in it that let a brief overrule the warning never
# reached a lane. There is one lane message now, and it carries that sentence.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
payload=$(cat)

# A lane has an agent_id. It is a different subject: a different budget, a
# different instruction, and a ladder of its own — several lanes share one
# session_id, so a state file keyed on that alone would have the first lane's
# rungs silence the rest.
agent=$(jq -r '.agent_id // empty' <<<"$payload")

if [ -n "$agent" ]; then
	budget=${CLAUDE_LANE_BUDGET:-}
	default_file="$here/lane-budget.default"
else
	budget=${CLAUDE_CONTEXT_BUDGET:-}
	default_file="$here/context-budget.default"
fi
if [ -z "$budget" ]; then
	budget=$(cat "$default_file" 2>/dev/null)
	case "$budget" in '' | *[!0-9]*)
		echo "context-budget.sh: can't read a default from $default_file" >&2
		exit 1
		;;
	esac
fi

step=${CLAUDE_CONTEXT_BUDGET_STEP:-25000}
case "$step" in '' | *[!0-9]* | 0) step=25000 ;; esac

session=$(jq -r '.session_id // "unknown"' <<<"$payload")
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")
event=$(jq -r '.hook_event_name // "Stop"' <<<"$payload")

# A lane is handed its session's transcript, not its own; the section above on
# where a lane's own figure lives says why every project directory is searched.
if [ -n "$agent" ]; then
	projects=$(dirname "$(dirname "$transcript")")
	lane_transcript=
	for candidate in "$projects"/*/"$session"/subagents/agent-"$agent".jsonl \
		"$projects"/*/"$session"/subagents/workflows/*/agent-"$agent".jsonl; do
		[ -r "$candidate" ] && lane_transcript=$candidate && break
	done
	if [ -z "$lane_transcript" ]; then
		echo "context-budget.sh: no transcript for lane $agent under $projects/*/$session/subagents" >&2
		exit 1
	fi
	transcript=$lane_transcript
fi
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
state="${TMPDIR:-/tmp}/claude-context-budget-$session${agent:+-$agent}"
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

# Grouped by hand: `printf "%'d"` groups thousands only under a locale that has a
# separator, so the same warning read "26,000" here and "26000" on a runner in C.
grouped() {
	local n=$1 out=
	while [ ${#n} -gt 3 ]; do
		out=,${n: -3}$out
		n=${n:0:${#n}-3}
	done
	printf '%s%s' "$n" "$out"
}
pretty=$(grouped "$tokens")
cap=$(grouped "$budget")

# The first warning's line is word for word what it has always been, so a
# measurement over a window that spans this change can still count crossings; a
# repeat says so, and is countable on its own.
if [ -n "$agent" ]; then
	if [ "$last" -lt 0 ]; then
		headline="Lane budget passed at $tokens tokens — commit and report."
		opening="This lane's context is at $pretty input tokens, past the $cap a lane is budgeted."
	else
		grown=$(grouped $((tokens - first)))
		headline="Lane budget still growing: $tokens tokens, $grown more since the first warning — report and stop."
		opening="This lane's context is at $pretty input tokens, past the $cap a lane is budgeted — $grown more than when you were first told, and that first time was not heeded."
	fi
elif [ "$last" -lt 0 ]; then
	headline="Context budget passed at $tokens tokens — handoff suggested."
	opening="Context is at $pretty input tokens, past the $cap budget. Raise it for a session with CLAUDE_CONTEXT_BUDGET."
else
	grown=$(grouped $((tokens - first)))
	headline="Context budget still growing: $tokens tokens, $grown more since the first warning — handoff overdue."
	opening="Context is at $pretty input tokens, past the $cap budget — $grown more than when you were first told, and that first time was not heeded. Every response since has been billed at more than a fresh session would pay for the same call."
fi

if [ -n "$agent" ]; then
	read -r -d '' reason <<EOF || true
$opening

Finish the call you are on — do not abandon a commit, a test run or a
half-written file — and then stop rather than starting the next thing. A lane's
handoff is its report:

1. Commit what is done, with an explicit \`git add <path>\` per file.
2. Report what is left — what you finished, what remains, and what you learned
   that the next lane would otherwise rediscover.

You cannot hand off to another session and you cannot raise this budget; the
dispatcher sets it. If your brief explicitly told you to run past this point,
say so in the report and carry on.
EOF
elif [ "$event" = "PostToolUse" ]; then
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
