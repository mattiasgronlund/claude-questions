#!/usr/bin/env bash
# Two lines that answer "how close am I to a handoff" and "what is waiting on
# me", without either question costing a token.
#
# This exists because the obvious way to check — `!cat` on the questions file —
# is not free. Shell mode adds its output to the session and Claude answers it:
# on 2026-09-05 that put 21 command outputs and 5,710 characters into context
# that nobody needed the model to read. The status line is terminal UI. It never
# reaches the model, so it can be re-read as often as you like.
#
# Line 1 tracks the same budget `context-budget.sh` enforces, so the handoff is
# visible on the way in rather than announced on arrival.
#
# Line 2 is the open question numbers and nothing else. The questions live in
# the session's own scratchpad, never in the tree: on 2026-09-05 four sessions
# were live across these two repos, and a tracked file would have had all four
# writing to it. Per session also means the numbering is the session's own, so
# "Q3-Q8" means what it says in the conversation you are looking at.
set -uo pipefail

payload=$(cat)
budget=${CLAUDE_CONTEXT_BUDGET:-250000}

get() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null; }

model=$(get '.model.display_name')
used=$(get '.context_window.total_input_tokens')
root=$(get '.workspace.project_dir')
tree=$(get '.workspace.git_worktree')
[ -n "$root" ] || root=$(get '.cwd')
branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)

dim=$'\033[2m'
off=$'\033[0m'
green=$'\033[32m'
yellow=$'\033[33m'
red=$'\033[31m'

# --- line 1: context against the handoff budget
line1="${model:-claude}"
[ -n "$tree" ] && line1="$line1 ${dim}·${off} $tree"
[ -n "$branch" ] && [ "$branch" != HEAD ] && line1="$line1 ${dim}·${off} $branch"

case "$used" in
'' | *[!0-9]*) used='' ;;
esac
if [ -n "$used" ]; then
	pct=$((used * 100 / budget))
	filled=$((pct / 10))
	[ "$filled" -gt 10 ] && filled=10
	[ "$filled" -lt 0 ] && filled=0
	colour=$green
	[ "$pct" -ge 70 ] && colour=$yellow
	[ "$pct" -ge 100 ] && colour=$red
	bar=""
	for i in $(seq 1 10); do
		if [ "$i" -le "$filled" ]; then bar="$bar▓"; else bar="$bar░"; fi
	done
	note=""
	[ "$pct" -ge 100 ] && note=" hand off"
	line1="$line1 ${dim}·${off} ${colour}$((used / 1000))k/$((budget / 1000))k ${bar} ${pct}%${note}${off}"
fi
printf '%s\n' "$line1"

# --- line 2: which questions are still open, by number
# The transcript sits at <projects>/<slug>/<session>.jsonl and the scratchpad at
# <tmp>/claude-<uid>/<slug>/<session>/scratchpad, so one names the other.
session=$(get '.session_id')
questions=${CLAUDE_QUESTIONS_FILE:-}
if [ -z "$questions" ]; then
	transcript=$(get '.transcript_path')
	if [ -n "$session" ] && [ -n "$transcript" ]; then
		slug=$(basename "$(dirname "$transcript")")
		for base in "${TMPDIR:-/tmp}" /tmp; do
			candidate="$base/claude-$(id -u)/$slug/$session/scratchpad/open-questions.md"
			[ -r "$candidate" ] && questions=$candidate && break
		done
	fi
fi
[ -n "$questions" ] && [ -r "$questions" ] || exit 0

# The grammar lives in `questions.py` beside this file and not here. It used to
# live in both, kept in step by a comment claiming they matched, and they did
# not: an entry carrying two labels, `**Q7 / Q11**`, counted as one, and Q11 and
# Q27 sat open all of 2026-09-06 while this line showed fourteen of the sixteen
# and looked complete. A question the file records and the line does not show is
# the one failure this line cannot have, and one parser is how that is
# guaranteed rather than asserted.
#
# One process rather than the four this used to fork, which is also why it got
# faster: 27.8 ms to 15.6 ms, measured, on a line that redraws every 5 seconds.
#
# Resolved beside this script rather than through `CLAUDE_QUESTIONS_PLUGIN`: the
# variable is how a *repo* finds this plugin, and once you are inside it the
# parser is a sibling. Reading the variable here would let a wrapper point at
# one plugin and get another plugin's grammar.
here=$(dirname "$(readlink -f "$0")")
compact=$(python3 "$here/questions.py" compact "$questions")

if [ -z "$compact" ]; then
	printf '%s\n' "${green}✓${off} ${dim}no open questions${off}"
	exit 0
fi

# The hash is the address `just question` takes, and it is here because nothing
# else knows it: the file is named by the session id, which only the harness
# has. Six characters, which is enough to address a session and short enough to
# sit in front of the labels without crowding them.
tag=""
[ -n "$session" ] && tag="${dim}${session:0:6}${off} "
printf '%s\n' "${yellow}❓${off} $tag$compact"
