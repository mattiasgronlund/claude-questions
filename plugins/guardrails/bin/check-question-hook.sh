#!/usr/bin/env bash
# Runs the PostToolUse question-file hook against its cases and reports any
# that came out wrong.
#
# The one case worth naming: a hook that cannot resolve the checker and a hook
# that resolved it against a clean file both print nothing on the happy path.
# Without a case that deliberately breaks resolution, a typo in the fallback
# chain reads as "every file is clean" forever. So this file proves both the
# quiet success and the loud failure, not just the quiet success.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
hook=$(dirname "$here")/hooks/check-question-file.sh
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

resolved "a clean open-questions.md stays silent" \
	"$work/clean-open-questions.md" 0 yes ""

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

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total question-hook cases came out wrong"
	exit 1
fi

echo "$total question-hook cases, all as expected"
