#!/usr/bin/env bash
# Runs the two hooks that guard the question file against their cases, and
# reports any that came out wrong: the PostToolUse checker, and the PreToolUse
# refusal of a `just question-check` the checker has already answered.
#
# The one case worth naming: a hook that cannot resolve the checker and a hook
# that resolved it against a clean file used to print nothing alike. Without a
# case that deliberately breaks resolution, a typo in the fallback chain reads
# as "every file is clean" forever. A clean file now says so — which is §152's
# change and why the silence cases below are worth more than they look: the
# *unresolvable* case must still print nothing, because the one thing worse
# than silence is a hook that says "clean" without having looked.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
hook=$(dirname "$here")/hooks/check-question-file.sh
refusal=$(dirname "$here")/hooks/no-hand-run-question-check.sh
questions_plugin=$(dirname "$(dirname "$here")")/questions

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/home"

cat >"$work/clean-open-questions.md" <<'MD'
# Open questions

- [ ] **Q1** — A short heading, in one line?

  The body, as many paragraphs as it takes.

  - **(a)** the first option
  - **(b)** the second

  ➡️ *Recommend (a), because reasons.*
MD

cat >"$work/broken-open-questions.md" <<'MD'
# Open questions

- [ ] **Q1** no separator between the label and the heading
MD

failed=0
total=0

payload() {
	jq -n --arg f "$1" '{tool_name: "Write", tool_input: {file_path: $f}}'
}

# Cases where the checker resolves via CLAUDE_QUESTIONS_PLUGIN, pointed at this
# checkout's own questions plugin — the same thing statusline.sh does.
resolved() {
	local why=$1 file=$2 want_exit=$3 want_stdout_empty=$4 want_stdout_substr=$5
	total=$((total + 1))
	local out err got_exit
	out=$(payload "$file" | CLAUDE_QUESTIONS_PLUGIN="$questions_plugin" \
		env -u CLAUDE_PLUGINS_ROOT -u CLAUDE_CONFIG_DIR HOME="$work/home" "$hook" 2>"$work/err")
	got_exit=$?
	err=$(cat "$work/err")
	if [ "$got_exit" != "$want_exit" ]; then
		printf 'wanted exit %s, got %s: %s\n  stderr: %s\n' "$want_exit" "$got_exit" "$why" "$err"
		failed=$((failed + 1))
		return
	fi
	if [ "$want_stdout_empty" = yes ] && [ -n "$out" ]; then
		printf 'wanted silence, got output: %s\n  %s\n' "$why" "$out"
		failed=$((failed + 1))
		return
	fi
	if [ -n "$want_stdout_substr" ] && ! grep -qF "$want_stdout_substr" <<<"$out"; then
		printf 'wanted stdout to mention %q: %s\n  got: %s\n' "$want_stdout_substr" "$why" "$out"
		failed=$((failed + 1))
	fi
}

resolved "a file that is not open-questions.md stays silent" \
	"$work/src/meet.rs" 0 yes ""

# A clean file says so, and says it where the model can read it. Plain stdout
# on a PostToolUse hook goes to the debug log and nowhere else, so a
# confirmation that is not in `additionalContext` is the old silence wearing a
# hat. That is the whole of §152's first half, so it is checked by field and
# not by substring.
total=$((total + 1))
out=$(payload "$work/clean-open-questions.md" | CLAUDE_QUESTIONS_PLUGIN="$questions_plugin" \
	env -u CLAUDE_PLUGINS_ROOT -u CLAUDE_CONFIG_DIR HOME="$work/home" "$hook" 2>"$work/err")
got_exit=$?
if [ "$got_exit" != 0 ]; then
	printf 'wanted exit 0 on a clean file, got %s\n  stderr: %s\n' "$got_exit" "$(cat "$work/err")"
	failed=$((failed + 1))
elif ! jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$out" >/dev/null 2>&1; then
	printf 'wanted a PostToolUse hookSpecificOutput on a clean file, got: %s\n' "$out"
	failed=$((failed + 1))
elif ! jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" | grep -qF "clean"; then
	printf 'wanted the clean-file confirmation in additionalContext, got: %s\n' "$out"
	failed=$((failed + 1))
elif ! jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" | grep -qF "Q1"; then
	printf 'wanted the open labels carried in the confirmation, got: %s\n' "$out"
	failed=$((failed + 1))
elif jq -e 'has("decision")' <<<"$out" >/dev/null 2>&1; then
	printf 'a clean file must not block, got: %s\n' "$out"
	failed=$((failed + 1))
fi

total=$((total + 1))
out=$(payload "$work/broken-open-questions.md" | CLAUDE_QUESTIONS_PLUGIN="$questions_plugin" \
	env -u CLAUDE_PLUGINS_ROOT -u CLAUDE_CONFIG_DIR HOME="$work/home" "$hook" 2>"$work/err")
got_exit=$?
if [ "$got_exit" != 0 ]; then
	printf 'wanted exit 0 (a violation is reported, not a hook failure), got %s\n' "$got_exit"
	failed=$((failed + 1))
elif ! jq -e '.decision == "block"' <<<"$out" >/dev/null 2>&1; then
	printf 'wanted a {"decision": "block", ...} reply to Claude, got: %s\n' "$out"
	failed=$((failed + 1))
elif ! jq -r '.reason' <<<"$out" | grep -qF "no separator"; then
	printf 'wanted the checker'"'"'s own finding in the reason, got: %s\n' "$out"
	failed=$((failed + 1))
fi

resolved "a missing target file stays silent rather than erroring" \
	"$work/never-written-open-questions.md" 0 yes ""

# The checker cannot be resolved: no override, no marketplace clone, and a HOME
# with none of the fallback checkout either. This is the case the hook exists
# to get loud about — silence here is indistinguishable from a clean file.
total=$((total + 1))
mkdir -p "$work/no-plugin-home"
out=$(payload "$work/clean-open-questions.md" |
	env -u CLAUDE_QUESTIONS_PLUGIN -u CLAUDE_PLUGINS_ROOT -u CLAUDE_CONFIG_DIR \
		HOME="$work/no-plugin-home" "$hook" 2>"$work/err")
got_exit=$?
err=$(cat "$work/err")
if [ "$got_exit" != 2 ]; then
	printf 'wanted exit 2 when the checker cannot be found, got %s\n  stderr: %s\n' "$got_exit" "$err"
	failed=$((failed + 1))
elif [ -n "$out" ]; then
	printf 'wanted no stdout when the checker cannot be found (nothing that reads as "clean"), got: %s\n' "$out"
	failed=$((failed + 1))
elif [ -z "$err" ]; then
	printf 'wanted stderr to say the checker could not be found, got silence\n'
	failed=$((failed + 1))
fi

# A file with nothing left open still says clean, and says what it found rather
# than an empty half-sentence. `compact` prints nothing when no entry is open,
# and a confirmation line ending in ", ." is the shape that makes a reader
# wonder whether the hook ran at all.
cat >"$work/answered-open-questions.md" <<'MD'
# Open questions

- [x] **Q1** — A short heading, in one line?

  → answered: **(a)**, by Mattias in his own turn.
MD

total=$((total + 1))
out=$(payload "$work/answered-open-questions.md" | CLAUDE_QUESTIONS_PLUGIN="$questions_plugin" \
	env -u CLAUDE_PLUGINS_ROOT -u CLAUDE_CONFIG_DIR HOME="$work/home" "$hook" 2>"$work/err")
if ! jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" | grep -qF "nothing open"; then
	printf 'wanted a file with nothing open to say so, got: %s\n' "$out"
	failed=$((failed + 1))
fi

# ------------------------------ the refusal -------------------------------
#
# `just question-check` is refused because the write already ran the checker.
# The cases that matter are the ones on the other side of that line: reading
# the recipe, quoting it in a heredoc, and reaching past it to the checker
# itself are all still allowed, and the last of those is the escape hatch the
# refusal message names. A guard that catches the mention rather than the call
# would take all three with it.
refused() {
	local why=$1 command=$2 want=$3
	total=$((total + 1))
	local out got
	out=$(jq -n --arg c "$command" '{tool_name: "Bash", tool_input: {command: $c}}' | "$refusal")
	if [ -z "$out" ]; then
		got=allow
	else
		got=$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out" 2>/dev/null)
	fi
	[ "$got" = "$want" ] && return
	printf 'wanted %s, got %s: %s\n' "$want" "$got" "$why"
	failed=$((failed + 1))
}

refused "the bare recipe" 'just question-check 766405' deny
refused "through mise, as every lane's brief says to run it" \
	'mise exec -- just question-check 766405' deny
refused "under timeout, with the runner's own argument in the way" \
	'timeout 60 just question-check abc123' deny
refused "in a command substitution" 'out=$(just question-check 766405)' deny
refused "second in a chain" 'just t --lib && just question-check 766405' deny

refused "reading the recipe rather than running it" \
	'grep -n question-check justfile' allow
refused "a commit message that describes the rule" \
	"$(printf 'git commit -F - <<%sMSG%s\nnever run just question-check by hand\nMSG\n' "'" "'")" allow
refused "the escape hatch the refusal names" \
	'python3 "$CLAUDE_PLUGINS_ROOT/questions/bin/questions.py" check /tmp/x/open-questions.md' allow
refused "reading the questions, which was never the expensive call" \
	'just question 766405' allow
refused "a recipe whose name merely starts the same way" \
	'just question-check-selftest' allow

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total question-hook cases came out wrong"
	exit 1
fi

echo "$total question-hook cases, all as expected"
