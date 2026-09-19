#!/usr/bin/env bash
# Refuses `just question-check` from a session, because the write already ran it.
#
# `check-question-file.sh` has run the same checker on every `Write` and `Edit`
# to `open-questions.md` since 2026-09-14. Sessions went on calling the recipe
# anyway: 174 calls in the week of 2026-09-12, 148 of them after the hook
# landed, and **three** found a violation. The other 171 asked a question that
# had already been answered in the turn that wrote the file, and each one billed
# the whole conversation to ask it — a median context of 146 000 tokens, about a
# tenth of a dollar, $17.58 for the week.
#
# **Prose was tried first and did not hold**, which is this plugin's whole
# subject. The `asking-questions` skill said to run the checker in the turn you
# write a question, and of 393 question-file responses that week not one put the
# write and the check in the same call. The skill now says the opposite; this
# refuses the call that the skill can only ask about.
#
# **It is safe to refuse because the two ship together.** A machine without this
# hook has no `check-question-file.sh` either — they are one plugin — so a
# refusal can only fire where the thing that makes the call redundant is
# installed. That is what lets this be a refusal rather than a warning.
#
# The escape hatch is the checker itself, named in the message: a session with a
# real reason to check a file it did not just write can run `questions.py check`
# directly. Reaching past the recipe is the signal that the reason was real.
#
# `docs/decisions.md` §151.
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/shell-code.sh"

command=$(jq -r '.tool_input.command // ""')
code=$(shell_code_of "$command")

# Command position, not a mention. `grep -n question-check justfile` reads the
# recipe and must pass; so must a commit message or a doc that quotes it. Only a
# segment whose head resolves to `just` counts, so the test is where the words
# sit rather than whether they appear.
segments=$(sed -E 's/\$\(/\n/g; s/`/\n/g; s/&&/\n/g; s/\|\|/\n/g; s/\|/\n/g; s/;/\n/g; s/\(/\n/g; s/\{/\n/g' <<<"$code")

runs_the_recipe() {
	local segment=$1 word i=0
	local -a words
	read -r -a words <<<"$segment"
	while [ "$i" -lt "${#words[@]}" ]; do
		word=${words[$i]}
		case "$word" in
		# A leading assignment, a runner, or a runner's own argument: all of
		# `RCAD_X=1 mise exec -- just …` and `timeout 600 just …` reach the
		# recipe, and the head word is none of those.
		*=* | mise | env | timeout | nohup | time | exec | command | -- | -* | [0-9]*)
			i=$((i + 1))
			continue
			;;
		esac
		break
	done
	[ "${words[$i]:-}" = just ] || return 1
	# `question-check` as a word of its own after `just`, so a recipe merely
	# named on the line — `just --list question-check-ish` — is not this one.
	for word in "${words[@]:$((i + 1))}"; do
		[ "$word" = question-check ] && return 0
	done
	return 1
}

while IFS= read -r segment; do
	runs_the_recipe "$segment" || continue
	jq -n --arg reason "$(
		cat <<'WHY'
`just question-check` is refused: the write already ran it. Every Write and Edit to open-questions.md runs the same checker through the guardrails PostToolUse hook, which blocks on a violation and confirms a clean file in one line — so this call bills the whole conversation to re-ask a question already answered. In the week of 2026-09-12 that happened 148 times and found three things.

If you have a reason to check a file you did not just write, run the checker directly: `python3 "$CLAUDE_PLUGINS_ROOT/questions/bin/questions.py" check <file>`.
WHY
	)" '{
		hookSpecificOutput: {
			hookEventName: "PreToolUse",
			permissionDecision: "deny",
			permissionDecisionReason: $reason
		}
	}'
	exit 0
done <<<"$segments"

exit 0
