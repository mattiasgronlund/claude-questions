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

# A repo that asks for a version, which is what makes the pin checkable at all.
# `pinned-repo` names v1.0.0 throughout; what changes between the cases below is
# the config directory it is read against.
mkdir -p "$dir/pinned-repo/.claude"
cat >"$dir/pinned-repo/.claude/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "acme-local": {
      "source": { "source": "github", "repo": "acme/plugins", "ref": "v1.0.0" }
    }
  },
  "enabledPlugins": { "alpha@acme-local": true, "beta@acme-local": true }
}
JSON

# Four machines, differing only in what `marketplace add` was run with. The
# plugins are declared in the repo above in every one, so the only thing any of
# these cases can be reporting on is the ref.
registered() {
	mkdir -p "$dir/$1/.claude/plugins"
	cat >"$dir/$1/.claude/plugins/known_marketplaces.json"
}
registered home-v1 <<'JSON'
{ "acme-local": { "source": { "source": "github", "repo": "acme/plugins", "ref": "v1.0.0" },
  "installLocation": "/somewhere", "lastUpdated": "2026-09-13T00:00:00.000Z" } }
JSON
registered home-v2 <<'JSON'
{ "acme-local": { "source": { "source": "github", "repo": "acme/plugins", "ref": "v2.0.0" },
  "installLocation": "/somewhere", "lastUpdated": "2026-09-13T00:00:00.000Z" } }
JSON
registered home-noref <<'JSON'
{ "acme-local": { "source": { "source": "github", "repo": "acme/plugins" },
  "installLocation": "/somewhere", "lastUpdated": "2026-09-13T00:00:00.000Z" } }
JSON
registered home-directory <<'JSON'
{ "acme-local": { "source": { "source": "directory", "path": "/home/someone/acme" },
  "installLocation": "/home/someone/acme", "lastUpdated": "2026-09-13T00:00:00.000Z" } }
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

# The pin. Every case below has the plugins declared, so a wrong verdict here
# cannot be blamed on the declaration half.
expect pinned-repo home-v1 home-v1/.claude 0 "pinned at v1.0.0" \
	"the ref asked for and the ref registered agree, and the line is the evidence"

expect pinned-repo home-v2 home-v2/.claude 1 "asks for v1.0.0 and acme-local is registered at v2.0.0" \
	"two versions that disagree is the failure the pin exists to make visible"

# The one that actually happens: `marketplace add acme/plugins`, with the
# `@v1.0.0` left off. The registration is valid, the plugins load, and the
# machine is on the default branch. Nothing but this line says so.
expect pinned-repo home-noref home-noref/.claude 1 "registered at the default branch" \
	"a missing ref is a version difference, not an absence of one"

expect pinned-repo home-directory home-directory/.claude 0 "escape hatch and not the pin" \
	"a working tree has no ref, and pointing one at a repo is supported: name it, do not fail it"

# The repo that asks for nothing still has to pass. Most repos never pin, and a
# check that reported on every one of them would be noise ending in a filter.
expect repo home-v2 home-v2/.claude 0 "declared to Claude Code" \
	"no ref asked for is nothing to compare, and nothing to compare is not a fault"

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total declaration cases came out wrong"
	exit 1
fi

echo "$total declaration cases, all as expected"
