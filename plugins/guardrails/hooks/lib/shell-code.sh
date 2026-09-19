#!/usr/bin/env bash
# The shell code of a Bash tool call, with any heredoc bodies taken out.
#
# Two hooks need this and they need the same answer. The command and its bodies
# are different things: a `git commit -F - <<'MSG'` whose message *describes* a
# rule is not breaking it, and the first version of the patching hook refused
# exactly that. So a hook that judges what a call *does* judges the code, and a
# body only matters where an interpreter is being fed one.
#
# It lives here rather than twice because a copy in each hook is a copy that
# goes stale, which is the whole reason this marketplace exists.
#
# Usage: code=$(shell_code_of "$command")

shell_code_of() {
	awk '
		skip { if ($0 ~ "^[ \t]*" delim "[ \t]*$") skip = 0; next }
		{ print }
		match($0, /<<-?[ \t]*'\''?"?[A-Za-z_][A-Za-z0-9_]*/) {
			delim = substr($0, RSTART, RLENGTH)
			sub(/^<<-?[ \t]*'\''?"?/, "", delim)
			skip = 1
		}
	' <<<"$1"
}
