#!/usr/bin/env bash
# Are these plugins declared to Claude Code, and not merely present on disk?
#
#     check-declared.sh <marketplace> <plugin>...
#
# A repo's own recipe can check that the plugin directory exists. That is the
# bootstrap and it has to live in the repo, because it is what runs when the
# plugin is missing. But a directory is not an install: clone the marketplace
# repo and never register it, and the files are all there while the session has
# no hooks and no skills. `rscene` hit exactly that — three plugin directories
# present, `check-plugins` green, nothing loaded.
#
# Two ways a plugin is declared, and either counts:
#
#   - `enabledPlugins` in a settings file, which is the declarative form and
#     what `/plugin install` cannot give you in a non-interactive session;
#   - an entry in `installed_plugins.json`, which is what the interactive
#     `/plugin install` panel writes.
#
# **This still cannot prove the running session loaded them.** Settings are read
# at session start, so a declaration written mid-session is true here and not yet
# true in the session reading it. What this rules out is the silent case — never
# declared at all — and it says so rather than claiming more.
#
# **Where there is no Claude Code to have been told, this skips rather than
# answering.** A runner supplies the plugins by pointing `CLAUDE_PLUGINS_ROOT`
# at a clone and has no config directory at all, so every file read below comes
# back empty and the only verdict available is a false "never declared". `rcad`
# found this the direct way: the first push whose CI ran the full gate died here
# in 31 s, naming all three plugins.
#
# **The predicate is the config directory, not `CI`.** That directory *is* the
# installation — settings, `known_marketplaces.json`, `installed_plugins.json` —
# so its absence is the thing itself rather than a proxy for it, and any machine
# a human works on has one. `CI` was the first draft and is worse in both
# directions: a human who exports it loses the check silently, and a runner that
# does not set it gets a red nobody can act on. `CLAUDE_CONFIG_DIR` moves the
# directory, so the skip and the reads below have to agree on where it is; they
# did not when this was `$HOME/.claude` written out four times.
#
# Skipping is not the same as passing, and this says which it did — §45 is the
# entry about tests that printed "skipping" and returned green until a green
# suite had never read a real file.
#
# The alternative was for a repo to commit an `enabledPlugins` block so the
# runner could read one out of its own checkout. That is green for a reason the
# runner does not have: declaring a plugin to a machine with no Claude Code
# enables nothing, and it needs `extraKnownMarketplaces` beside it, whose entire
# test here is `has($m)` — a placeholder value would pass while asserting
# nothing, which is the failure this script exists to catch.
set -uo pipefail

marketplace=${1:?usage: check-declared.sh <marketplace> <plugin>...}
shift
[ "$#" -gt 0 ] || { echo "no plugins named" >&2; exit 2; }

config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

if [ ! -d "$config" ]; then
	printf 'no %s, so no Claude Code to have been told about %s: the declaration check is skipped, not passed\n' \
		"$config" "$marketplace"
	exit 0
fi

settings=(
	"$config/settings.json"
	".claude/settings.json"
	".claude/settings.local.json"
)
installed="$config/plugins/installed_plugins.json"
known="$config/plugins/known_marketplaces.json"

declared() {
	local id=$1 file
	for file in "${settings[@]}"; do
		[ -r "$file" ] || continue
		[ "$(jq -r --arg k "$id" '.enabledPlugins[$k] // empty' "$file" 2>/dev/null)" = true ] && return 0
	done
	[ -r "$installed" ] &&
		jq -e --arg k "$id" '.plugins | has($k)' "$installed" >/dev/null 2>&1
}

missing=0

# The marketplace first: without it the plugin ids below name nothing, and
# "plugin not declared" would be a confusing way to report "no marketplace".
registered=no
[ -r "$known" ] && jq -e --arg m "$marketplace" 'has($m)' "$known" >/dev/null 2>&1 && registered=yes
if [ "$registered" = no ]; then
	for file in "${settings[@]}"; do
		[ -r "$file" ] || continue
		jq -e --arg m "$marketplace" '.extraKnownMarketplaces // {} | has($m)' "$file" >/dev/null 2>&1 &&
			registered=yes && break
	done
fi
if [ "$registered" = no ]; then
	printf 'marketplace %s is not registered\n' "$marketplace"
	missing=1
fi

for plugin in "$@"; do
	if ! declared "$plugin@$marketplace"; then
		printf 'plugin %s@%s is on disk but not declared to Claude Code\n' "$plugin" "$marketplace"
		missing=1
	fi
done

if [ "$missing" -eq 1 ]; then
	cat <<EOF

A plugin present but undeclared loads nothing: no hooks, no skills, and no
message saying so. Declare them by adding to a settings file

  "enabledPlugins": {
$(for p in "$@"; do printf '    "%s@%s": true,\n' "$p" "$marketplace"; done | sed '$ s/,$//')
  }

or install them interactively with /plugin install <name>@$marketplace.
Settings are read at session start, so a session already running needs a restart.
EOF
	exit 1
fi

printf '%d plugins declared to Claude Code via %s\n' "$#" "$marketplace"
