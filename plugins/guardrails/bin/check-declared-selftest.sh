#!/usr/bin/env bash
# `check-declared.sh` skips on CI, and only on CI. Both directions, because one
# of them is what the skip could quietly cost.
#
# A skip that is wrong in the CI direction turns a runner red and somebody
# notices within the hour. A skip that is wrong in the other direction turns the
# check off for every human and nothing says so — which is the silent case the
# check was written for, restored by its own fix. So the off-CI direction is the
# one this file exists for; the on-CI direction is here because a test of one
# direction is a test of neither.
#
# Every case runs against a `HOME` with no `.claude` in it and from a directory
# with no `.claude` either, which is the shape a runner has. That is also why
# this cannot reuse the caller's environment: the machine writing the plugin has
# all three plugins declared, so every case would pass for the wrong reason.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
declared=$here/check-declared.sh

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/home" "$dir/work"

failed=0

# `env -u CI` rather than `CI=`, because the check asks whether the variable is
# non-empty and a runner that sets it to the empty string is not a runner.
run() {
	local ci=$1
	shift
	if [ "$ci" = on ]; then
		(cd "$dir/work" && HOME="$dir/home" CI=true "$declared" "$@" 2>&1)
	else
		(cd "$dir/work" && HOME="$dir/home" env -u CI "$declared" "$@" 2>&1)
	fi
}

expect() {
	local ci=$1 want=$2 why=$3
	shift 3
	local got out
	out=$(run "$ci" "$@")
	got=$?
	if [ "$got" != "$want" ]; then
		printf 'with CI %s, wanted exit %s and got %s: %s\n' "$ci" "$want" "$got" "$why"
		printf '  %s\n' "$(head -1 <<<"$out")"
		failed=$((failed + 1))
	fi
}

expect on 0 "a runner has no Claude Code, so the question has no answer" \
	acme-local alpha beta

expect off 1 "off CI, an undeclared plugin is the silent case this check exists for" \
	acme-local alpha beta

# The third case is what stops the skip from being written as "always pass":
# off CI with a declaration present, the check must still say yes. Without it,
# an unconditional `exit 0` at the top of the script would pass both cases above.
mkdir -p "$dir/work/.claude"
cat >"$dir/work/.claude/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": { "acme-local": {} },
  "enabledPlugins": { "alpha@acme-local": true, "beta@acme-local": true }
}
JSON

expect off 0 "off CI, a declared plugin must still come back declared" \
	acme-local alpha beta

if [ "$failed" -gt 0 ]; then
	echo "$failed of 3 declaration cases came out wrong"
	exit 1
fi

echo "3 declaration cases, all as expected"
