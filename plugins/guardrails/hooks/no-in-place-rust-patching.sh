#!/usr/bin/env bash
# Blocks patching a tracked source or docs file through the shell: heredocs,
# `sed -i`, redirects. CLAUDE.md bans this outright; §49.5 found three of
# thirteen lanes doing it anyway, and recording it twice changed nothing. The
# stated risk is that a pattern which does not match fails quietly, which is
# what a diff review is worst at catching — so it is refused here instead.
#
# `.rs` was the whole guard until the 2026-09-05 session review counted a day
# of shell writes across two repos. This repo, carrying the hook, wrote six.
# The repo carrying neither the hook nor a CLAUDE.md wrote 161 to `.rs` and
# another 40 to `.toml` and `.md` — including a `python3 - <<'PY'` whose
# `s.replace(...)` rewrote `docs/roadmap.md`, the exact quiet failure this
# refuses. A ban the hook does not reach is a ban that does not hold, so the
# guard covers the three file kinds the tree actually keeps.
#
# The command and its heredoc bodies are judged apart, because they are
# different things. A `git commit -F - <<'MSG'` whose message *describes* this
# rule is not patching anything, and the first version of this hook refused
# exactly that. So: the shell code is what gets searched for an in-place edit,
# and a body only matters when an interpreter is being fed one.
#
# Scratch paths are exempt. CLAUDE.md keeps Bash for "one-off measurement
# scripts that write to the scratchpad", and a probe crate's `main.rs` under
# /tmp is one of those: it is not the tree, no review will read it, and the
# reason to hand-write it is that it is throwaway.
#
# Reading is untouched: `sed -n '10,20p'`, grep, git diff all pass.
set -uo pipefail

command=$(jq -r '.tool_input.command // ""')

# Split the shell code from any heredoc bodies it carries.
code=$(awk '
	skip { if ($0 ~ "^[ \t]*" delim "[ \t]*$") skip = 0; next }
	{ print }
	match($0, /<<-?[ \t]*'\''?"?[A-Za-z_][A-Za-z0-9_]*/) {
		delim = substr($0, RSTART, RLENGTH)
		sub(/^<<-?[ \t]*'\''?"?/, "", delim)
		skip = 1
	}
' <<<"$command")
bodies=$(comm -13 <(sort -u <<<"$code") <(sort -u <<<"$command") 2>/dev/null || true)

# A scratch path held in a variable is still a scratch path, and this hook reads
# the command as text. `S=/tmp/…/scratchpad; cat > "$S/fixture.md"` reached the
# guard as `$S/fixture.md`, which matches neither `^/tmp/` nor `scratchpad`, so a
# scratchpad write was refused with a message saying scratchpad writes are fine.
# Failing closed is the right direction, but not while claiming otherwise.
#
# Only assignments in this same command can matter: the Bash tool carries a
# working directory between calls and no shell state, so a variable set in an
# earlier call does not exist here either. One left unresolved stays unresolved
# and is still judged a tree file.
expand_assignments() {
	local text=$1 line name value known
	declare -A seen=()
	while IFS= read -r line; do
		name=${line%%=*}
		value=${line#*=}
		value=${value#[\"\']}
		value=${value%[\"\']}
		for known in "${!seen[@]}"; do
			value=${value//\$\{$known\}/${seen[$known]}}
			value=${value//\$$known/${seen[$known]}}
		done
		seen[$name]=$value
	done < <(grep -oE '(^|[[:space:];&|(])[A-Za-z_][A-Za-z0-9_]*=[^[:space:];|&)]+' <<<"$text" |
		sed 's/^[[:space:];&|(]*//')
	for known in "${!seen[@]}"; do
		text=${text//\$\{$known\}/${seen[$known]}}
		text=${text//\$$known/${seen[$known]}}
	done
	printf '%s' "$text"
}
code=$(expand_assignments "$code")

guarded='[^[:space:];|&"'"'"'()<>]*\.(rs|toml|md)\b'
redirect='>>?[[:space:]]*[^[:space:];|&]*\.(rs|toml|md)\b'
scratch='^/(tmp|var/tmp)/|scratchpad|(^|/)target/'

# True when the text names a guarded file that is not in a scratch area.
names_tree_file() {
	grep -oE "$guarded" <<<"$1" | grep -qvE "$scratch"
}

deny() {
	jq -n --arg reason "$1" '{
		hookSpecificOutput: {
			hookEventName: "PreToolUse",
			permissionDecision: "deny",
			permissionDecisionReason: $reason
		}
	}'
	exit 0
}

if grep -qE '\b(sed|perl|ruby)\b[^|;]*[[:space:]]-[a-zA-Z]*i' <<<"$code" &&
	names_tree_file "$code"; then
	deny "CLAUDE.md bans patching a tracked .rs, .toml or .md file in place. Use Read then Edit — Edit takes two strings and errors when a pattern does not match, where sed -i fails quietly. Writing under /tmp or a scratchpad is still fine."
fi

if names_tree_file "$(grep -oE "$redirect" <<<"$code")"; then
	deny "CLAUDE.md bans writing a tracked .rs, .toml or .md file from the shell. Use Write for a new file, Edit for a change — a redirect that goes wrong takes the file with it. Writing under /tmp or a scratchpad is still fine."
fi

# The code is judged here as well as the bodies, because a path handed to the
# interpreter as an argument is not in the body at all. That is not a
# hypothetical: the session that widened this hook then patched two tracked
# CLAUDE.md files with `python3 - "$W/CLAUDE.md" "$R/CLAUDE.md" <<'PY'`, and the
# body-only check waved it through.
if grep -qE '\b(python[0-9.]*|perl|ruby|node)\b[^|;]*<<' <<<"$code" &&
	names_tree_file "$code
$bodies"; then
	deny "CLAUDE.md bans heredoc patching of tracked .rs, .toml and .md files. In the M5 run this cost 145k tokens over 233 calls — a sixth of everything the run generated. Read then Edit instead."
fi

exit 0
