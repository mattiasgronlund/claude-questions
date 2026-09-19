#!/usr/bin/env bash
# Runs the questions grammar checker right after a write to `open-questions.md`,
# so a violation is caught in the same turn that made it rather than on the next
# `just question-check` call.
#
# Measured when it was written: 128 `question-check` calls costing $10.6, whose
# MEDIAN result was 31 bytes — the checker prints nothing on a clean file, so
# almost the entire cost was the round-trip of asking. Folding the check into
# the write removes that round-trip on the common, clean-file case.
#
# **It did not remove it, and the reason was the silence.** Through the week of
# 2026-09-12 sessions went on making the call anyway — 148 of them after this
# hook landed, three of which found something. A hook that says nothing on a
# clean file looks exactly like a hook that is not installed, so a clean file
# now says so; see the tail of this script.
#
# The checker lives in the `questions` plugin, not here, so it is resolved the
# same way `statusline.sh` resolves it: `CLAUDE_QUESTIONS_PLUGIN`, then
# `CLAUDE_PLUGINS_ROOT`, then the marketplace clone under
# `$CLAUDE_CONFIG_DIR/plugins/marketplaces/mattiasgronlund-local/plugins`, then
# `$HOME/git/mattiasgronlund/claude-questions/plugins`. A hardcoded path here
# breaks the moment CI (or any repo) sets `CLAUDE_PLUGINS_ROOT`, and it breaks
# SILENTLY — a hook that cannot find its checker looks exactly like a clean
# file, which is worse than the round-trip this hook exists to remove. So a
# resolution failure is reported, not swallowed: see the `checker not found`
# case below.
set -uo pipefail

payload=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$payload")

case "$file" in
*open-questions.md) ;;
*) exit 0 ;;
esac

config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
clone=$config/plugins/marketplaces/mattiasgronlund-local/plugins
[ -d "$clone" ] || clone=$HOME/git/mattiasgronlund/claude-questions/plugins
root=${CLAUDE_PLUGINS_ROOT:-$clone}
plugin=${CLAUDE_QUESTIONS_PLUGIN:-$root/questions}
checker=$plugin/bin/questions.py

if [ ! -r "$checker" ]; then
	echo "check-question-file.sh: can't find the questions checker at $checker (checked CLAUDE_QUESTIONS_PLUGIN, CLAUDE_PLUGINS_ROOT, the marketplace clone, then \$HOME/git/mattiasgronlund/claude-questions) — $file was not checked" >&2
	exit 2
fi

[ -r "$file" ] || exit 0

problems=$(python3 "$checker" check "$file" 2>&1)

if [ -n "$problems" ]; then
	jq -n --arg reason "$(printf '`just question-check` found a grammar violation in %s:\n\n%s' "$file" "$problems")" \
		'{decision: "block", reason: $reason}'
	exit 0
fi

# A clean file says so, in one line, rather than saying nothing.
#
# `additionalContext` and not plain stdout: for a PostToolUse hook Claude Code
# writes stdout to the debug log and the model never sees it, which would be the
# same silence under a different name.
#
# The line names the open labels because it costs nothing to carry them — the
# file has just been parsed — and because it is the one thing a session would
# otherwise read the file back for. `docs/decisions.md` §152.
open=$(python3 "$checker" compact "$file" 2>/dev/null)
[ -n "$open" ] || open="nothing open"

jq -n --arg context "$(printf 'The questions grammar checker ran on %s as part of this write: clean, %s. That is what `just question-check` does, so running it now re-asks a question already answered.' "${file##*/}" "$open")" \
	'{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
exit 0
