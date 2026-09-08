#!/usr/bin/env bash
# `check-declared.sh` skips where there is no Claude Code, and only there.
#
# A skip that is wrong in the runner direction turns CI red and somebody notices
# within the hour. A skip that is wrong in the other direction turns the check
# off for every human and nothing says so — which is the silent case the check
# was written for, restored by its own fix. So the human direction is the one
# this file exists for; the runner direction is here because a test of one
# direction is a test of neither.
#
# Exit codes alone are not enough: skipping and passing are both `0`, so an
# unconditional `exit 0` at the top would satisfy them. Each case also names a
# phrase the output has to carry, which is what tells the two apart.
#
# Every case runs against a config directory this script made, and from a
# working directory this script made. That is not tidiness — the machine
# developing the plugin has all three plugins declared, so a case reading the
# caller's own environment would pass for the wrong reason. That is exactly how
# the bug being fixed here got through its first verification.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
declared=$here/check-declared.sh

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# A home with no Claude Code in it, and a home with one.
mkdir -p "$dir/bare-home"
mkdir -p "$dir/home/.claude/plugins"

# A repo that declares nothing, and a repo that declares both plugins. Two
# directories rather than one file written half way through, so no case depends
# on running after another.
mkdir -p "$dir/bare-repo"
mkdir -p "$dir/repo/.claude"
cat >"$dir/repo/.claude/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": { "acme-local": { "source": "acme/plugins" } },
  "enabledPlugins": { "alpha@acme-local": true, "beta@acme-local": true }
}
JSON

failed=0
total=0

# `home` and `configdir` are paths or the empty string, which means "leave the
# variable unset". `env -u` rather than `VAR=`, because the script asks whether
# `CLAUDE_CONFIG_DIR` is empty and a caller that sets it to nothing has not
# chosen a directory.
expect() {
	local repo=$1 home=$2 configdir=$3 want_exit=$4 want_text=$5 why=$6
	local out got
	total=$((total + 1))
	out=$(
		cd "$dir/$repo" || exit 99
		if [ -n "$configdir" ]; then
			HOME="$dir/$home" CLAUDE_CONFIG_DIR="$dir/$configdir" "$declared" acme-local alpha beta 2>&1
		else
			HOME="$dir/$home" env -u CLAUDE_CONFIG_DIR "$declared" acme-local alpha beta 2>&1
		fi
	)
	got=$?
	if [ "$got" != "$want_exit" ]; then
		printf 'wanted exit %s, got %s: %s\n  %s\n' "$want_exit" "$got" "$why" "$(head -1 <<<"$out")"
		failed=$((failed + 1))
	elif ! grep -qF "$want_text" <<<"$out"; then
		printf 'wanted the output to say %s: %s\n  %s\n' "$want_text" "$why" "$(head -1 <<<"$out")"
		failed=$((failed + 1))
	fi
}

expect bare-repo bare-home "" 0 "skipped, not passed" \
	"a runner has no config directory, so there is nothing to have been told"

expect bare-repo home "" 1 "not declared" \
	"with Claude Code present, an undeclared plugin is the silent case this catches"

expect repo home "" 0 "declared to Claude Code" \
	"with Claude Code present, a declared plugin still has to come back declared"

# The two `CLAUDE_CONFIG_DIR` cases are one claim in two halves: the skip and the
# file reads must agree on where the installation is. While the paths were
# written out as `$HOME/.claude` in four places and the skip asked about a
# fifth, they could not.
expect repo bare-home home/.claude 0 "declared to Claude Code" \
	"a relocated config directory is still a config directory, so do not skip"

expect repo home nowhere 0 "skipped, not passed" \
	"the reads follow CLAUDE_CONFIG_DIR, so the skip must follow it too"

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total declaration cases came out wrong"
	exit 1
fi

echo "$total declaration cases, all as expected"
