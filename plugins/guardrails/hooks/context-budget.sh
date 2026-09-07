#!/usr/bin/env bash
# Tells the dispatcher to hand off once its context passes a budget.
#
# Every turn pays for its whole context again. CLAUDE.md already caps a *lane*
# at about 45 minutes for this reason, and the lanes obey it — 51 of them on
# 2026-09-05, median 17 minutes, none over 45. The dispatchers had no such cap
# and were the expensive half of the day: 1994 turns, 485M input tokens, 97% of
# it cache reads, while writing almost no code.
#
# Measured against that day, capping a dispatcher at 250k would have removed
# 131M input tokens — 27% of all dispatcher cost. 300k removes 96M and 400k
# removes 45M. The number is a dial, not a discovery; it started at 300k and was
# turned down once the handoff was cheap enough to take more often.
#
# Fires once per session, on the two events where handing off is actually the
# next thing that could happen: when the user submits new work, and when a turn
# ends. Never in a subagent — a lane is short by construction and has nowhere to
# hand off to.
set -uo pipefail

payload=$(cat)
budget=${CLAUDE_CONTEXT_BUDGET:-250000}

# A lane has an agent_id; it is not the session this is about.
[ -n "$(jq -r '.agent_id // empty' <<<"$payload")" ] && exit 0

session=$(jq -r '.session_id // "unknown"' <<<"$payload")
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")
event=$(jq -r '.hook_event_name // "Stop"' <<<"$payload")
[ -r "$transcript" ] || exit 0

warned="${TMPDIR:-/tmp}/claude-handoff-warned-$session"
[ -e "$warned" ] && exit 0

# The last assistant turn's total input: fresh tokens plus everything re-read
# from cache. Only the tail is scanned — these files reach megabytes, and this
# runs at the end of every turn.
tokens=$(tail -n 400 "$transcript" 2>/dev/null |
	jq -R 'fromjson? | select(.type == "assistant") | .message.usage |
		(.input_tokens // 0) + (.cache_creation_input_tokens // 0) +
		(.cache_read_input_tokens // 0)' 2>/dev/null | tail -n 1)

case "$tokens" in
'' | *[!0-9]*) exit 0 ;;
esac
[ "$tokens" -lt "$budget" ] && exit 0

: >"$warned"

read -r -d '' reason <<EOF || true
Context is at $(printf "%'d" "$tokens") input tokens, past the $(printf "%'d" "$budget") budget. Raise it for a session with CLAUDE_CONTEXT_BUDGET.

Every further turn pays this whole context again, and a dispatcher at this size
is re-reading far more than it is deciding. Hand off now rather than at the end
of the next unit:

1. Call the handoff skill. Say what the next session is for.
2. Finish or park what is in flight — commit it, or say in the doc that it is not committed.
3. Tell the user the handoff path and that a fresh session should pick it up.

Do this before starting new work, not after. If the user has explicitly asked
you to keep going in this session, say what it costs and then keep going.
EOF

jq -n --arg r "$reason" --arg e "$event" --arg t "$tokens" '{
	systemMessage: ("Context budget passed at " + $t + " tokens — handoff suggested."),
	additionalContext: $r,
	hookSpecificOutput: { hookEventName: $e, additionalContext: $r }
}'
exit 0
