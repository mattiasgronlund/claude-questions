#!/usr/bin/env bash
# Runs the patching hook against its cases and reports any that came out wrong.
# An optional repo overlay of extra cases is appended to the shipped ones.
#
# The cases live in a JSON file rather than in this script, and that is not
# tidiness: a runner holding `sed -i ... .rs` as a literal is a command line the
# hook itself refuses, so a self-test written inline cannot run. The hook
# blocked two earlier drafts of its own test before this arrangement.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
hook=$(dirname "$here")/hooks/no-in-place-rust-patching.sh
cases=$(dirname "$here")/hooks/patching-cases.json
overlay=${1:-${GUARDRAILS_PATCHING_OVERLAY:-}}

# An overlay named but absent is a wiring mistake, not an empty overlay. Staying
# quiet about it would mean a repo's own cases silently stopping being run,
# which is the drift this plugin exists to end.
if [ -n "$overlay" ] && [ ! -r "$overlay" ]; then
	printf 'overlay named but not readable: %s\n' "$overlay" >&2
	exit 1
fi

merged=$(mktemp)
trap 'rm -f "$merged"' EXIT
if [ -n "$overlay" ]; then
	jq -s 'add' "$cases" "$overlay" >"$merged"
else
	cp "$cases" "$merged"
fi

failed=0
total=$(jq length "$merged")

for index in $(seq 0 $((total - 1))); do
	command=$(jq -r ".[$index].command" "$merged")
	expect=$(jq -r ".[$index].expect" "$merged")
	why=$(jq -r ".[$index].why" "$merged")

	got=$(jq -n --arg c "$command" '{tool_input: {command: $c}}' |
		"$hook" | jq -r '.hookSpecificOutput.permissionDecision // empty')
	[ -n "$got" ] || got=allow

	if [ "$got" != "$expect" ]; then
		printf 'wanted %s, got %s: %s\n' "$expect" "$got" "$why"
		printf '  %s\n' "$(head -1 <<<"$command")"
		failed=$((failed + 1))
	fi
done

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total patching cases came out wrong"
	exit 1
fi

echo "$total patching cases, all as expected"
