#!/usr/bin/env bash
# Runs the TUI's core against its cases. The core is everything the program does
# that is not drawing — finding sessions, judging them live or dead, and turning
# a batch of answers into the text you paste — and it is separated from the
# curses layer precisely so it can be run here.
#
# Drawing is not tested. The bugs this repo has actually had were grammar and
# counting bugs, and every one of them lives in the half this file drives; a pty
# harness would be the largest thing in the repo and would mostly test curses.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
tui="$here/questions-tui.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root="$work/root"
scratch="$root/-home-mattias-git-mattiasgronlund-rcad/76640573-f351-4e74-b0c3-000000000001/scratchpad"
mkdir -p "$scratch"
file="$scratch/open-questions.md"

failed=0
total=0

fail() {
	printf '  %s\n' "$1"
	failed=$((failed + 1))
}

same() {
	total=$((total + 1))
	[ "$2" = "$3" ] && return
	fail "$1"
	printf '    got:  %s\n    want: %s\n' "$(tr '\n' '|' <<<"$2")" "$(tr '\n' '|' <<<"$3")"
}

holds() {
	total=$((total + 1))
	grep -qE "$3" <<<"$2" || fail "$1"
}

lacks() {
	total=$((total + 1))
	grep -qE "$3" <<<"$2" && fail "$1"
}

# --- composing the text you paste
#
# The shape is the one a person types by hand, and these are the four shapes
# Mattias wrote out when he was asked what the program should produce.
compose() {
	printf '%s' "$2" >"$work/spec.json"
	python3 "$tui" compose "$work/spec.json"
}

answers() {
	local list=""
	for entry in "$@"; do
		IFS=: read -r label kind text <<<"$entry"
		[ -n "$list" ] && list="$list,"
		list="$list$(jq -nc --arg l "$label" --arg k "$kind" --arg t "$text" \
			'{label: $l, kind: $k, text: $t}')"
	done
	jq -nc --arg s "45d6bd" --arg r "claude-questions" --argjson a "[$list]" \
		'{session: $s, repo: $r, answers: $a}'
}

all_agreed=$(compose "everything agreed" "$(answers Q1:agree: Q2:agree: Q3:agree: \
	Q4:agree: Q5:agree: Q6:agree: Q7:agree: Q8:agree:)")
same "agreeing with everything did not collapse into one line" \
	"$(tail -n +3 <<<"$all_agreed")" "I agree on Q1-Q8"

with_one=$(compose "one differs" "$(answers Q1:agree: Q2:agree: Q4:agree: \
	Q5:agree: Q6:agree: Q7:agree: Q8:agree: 'Q3:option:(c)')")
same "an agreed run with one exception drifted from the idiom" \
	"$(tail -n +3 <<<"$with_one")" \
	"$(printf '%s\n' 'I agree on Q1, Q2, Q4-Q8 but:' '  Q3: (c)')"

# The run collapsing is `questions.py`'s, called from one more place rather than
# written a second time. If these two ever disagree, one of them is a copy.
same "the agree line and the status line collapse differently" \
	"$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import questions; print(questions.collapse(sys.argv[2:]))' \
		"$here" Q1 Q2 Q4 Q5 Q6 Q7 Q8)" \
	"Q1, Q2, Q4-Q8"

only_one=$(compose "nothing agreed" "$(answers 'Q3:option:(c)')")
same "a lone answer grew a header it does not need" \
	"$(tail -n +3 <<<"$only_one")" "Q3: (c)"

prose=$(compose "prose instead of a letter" "$(answers Q1:agree: \
	'Q3:prose:none of those, the third thing instead')")
same "a typed answer did not sit under the agree line" \
	"$(tail -n +3 <<<"$prose")" \
	"$(printf '%s\n' 'I agree on Q1 but:' '  Q3: none of those, the third thing instead')"

# A reply that settles nothing must not read as one that does, or Claude closes
# a question that is still open — the one failure this whole file exists to
# prevent, arriving from the other direction.
half=$(compose "a reply that keeps the question open" "$(answers Q1:agree: \
	'Q5:open:say more about the second one first')")
holds "a non-answer was not marked as leaving the question open" "$half" 'still open:'
holds "the open reply lost its text" "$half" 'say more about the second one first'
lacks "a reply that settles nothing was written under but:" "$half" 'but:'

both=$(compose "all three sections" "$(answers Q1:agree: 'Q3:option:(c)' 'Q5:open:not yet')")
same "the three sections came out in the wrong shape" \
	"$(tail -n +3 <<<"$both")" \
	"$(printf '%s\n' 'I agree on Q1 but:' '  Q3: (c)' '' 'still open:' '  Q5: not yet')"

# The header is the guard against a wrong-window paste: every grilling round in
# every session is numbered from Q1, so answers pasted into the wrong terminal
# land on questions that have those numbers too and read as valid.
holds "the composed text does not name the session it is for" "$all_agreed" '^45d6bd — claude-questions$'

sorted=$(compose "out of order" "$(answers 'Q10:option:(a)' 'Q9:option:(b)' 'K2:option:(a)')")
same "answers were not ordered by label" \
	"$(tail -n +3 <<<"$sorted")" \
	"$(printf '%s\n' 'K2: (a)' 'Q9: (b)' 'Q10: (a)')"

# --- the session listing
printf '%s\n' \
	'# Open questions' \
	'' \
	'- [ ] **Q1** — one?' \
	'- [ ] **Q2** — two?' \
	'- [x] **Q3** — settled → answered: yes' \
	>"$file"

# `claude agents --json` is stubbed with a file, because a test that needs a
# live session is a test that does not run. The pid is this shell's own, which
# is alive by definition for as long as the case takes.
jq -nc --argjson pid $$ \
	'[{pid: $pid, cwd: "/home/mattias/git/mattiasgronlund/rcad", kind: "interactive",
	   sessionId: "76640573-f351-4e74-b0c3-000000000001", name: "rcad-15", status: "busy"}]' \
	>"$work/agents.json"

listing=$(CLAUDE_QUESTIONS_AGENTS_JSON="$work/agents.json" python3 "$tui" sessions "$root")
holds "the listing lost the session" "$listing" '766405'
holds "the open count is not the parser's count" "$listing" '2 open'
holds "a live session was not named from claude agents" "$listing" 'rcad-15'
holds "a live session was not marked live" "$listing" 'live$'
holds "the repo came from the slug rather than the session's own directory" "$listing" 'rcad'

# The repo name matters because it goes in the pasted header. The slug's last
# segment turns `claude-questions` into `questions`, which is not what anyone
# would type.
other="$root/-home-mattias-git-mattiasgronlund-claude-questions/76640573-f351-4e74-b0c3-000000000002/scratchpad"
mkdir -p "$other"
printf '%s\n' '- [ ] **Q1** — one?' >"$other/open-questions.md"
jq -nc --argjson pid $$ \
	'[{pid: $pid, cwd: "/home/mattias/git/mattiasgronlund/claude-questions",
	   sessionId: "76640573-f351-4e74-b0c3-000000000002", name: "cq", status: "idle"}]' \
	>"$work/agents2.json"
listing=$(CLAUDE_QUESTIONS_AGENTS_JSON="$work/agents2.json" python3 "$tui" sessions "$root")
holds "the repo name was taken from the slug, not the working directory" \
	"$listing" 'claude-questions'

# A pid that no longer exists is the liveness test, because `claude agents`
# lists sessions that ended months ago as idle. 2 is init's child on Linux and
# never this user's session; a pid this user cannot signal counts as gone.
jq -nc '[{pid: 2, cwd: "/home/mattias/git/mattiasgronlund/rcad",
	  sessionId: "76640573-f351-4e74-b0c3-000000000001", name: "long-gone", status: "idle"}]' \
	>"$work/dead.json"
listing=$(CLAUDE_QUESTIONS_AGENTS_JSON="$work/dead.json" python3 "$tui" sessions "$root")
holds "a session whose pid is gone was not marked dead" "$listing" 'dead$'
lacks "a dead session was reported live because its status said idle" "$listing" ' live$'

# Unknown is not dead. With no `claude` on the path every session is unknown,
# and hiding them all would leave an empty picker with nothing to explain it.
printf '%s\n' '[]' >"$work/none.json"
listing=$(CLAUDE_QUESTIONS_AGENTS_JSON="$work/none.json" python3 "$tui" sessions "$root")
holds "a session the agent list does not know was dropped" "$listing" '766405'
holds "an unknown session was called dead" "$listing" 'unknown$'

# A malformed agents file is a normal answer, not a traceback: the listing still
# has to come out, because the questions are readable whatever `claude` says.
printf '%s\n' 'not json at all' >"$work/broken.json"
listing=$(CLAUDE_QUESTIONS_AGENTS_JSON="$work/broken.json" python3 "$tui" sessions "$root" 2>&1)
holds "a broken agent listing took the questions with it" "$listing" '766405'

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total TUI cases came out wrong"
	exit 1
fi

echo "$total TUI cases, all as expected"
