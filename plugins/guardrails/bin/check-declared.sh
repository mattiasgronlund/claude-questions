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
set -uo pipefail

marketplace=${1:?usage: check-declared.sh <marketplace> <plugin>...}
shift
[ "$#" -gt 0 ] || { echo "no plugins named" >&2; exit 2; }

settings=(
	"$HOME/.claude/settings.json"
	".claude/settings.json"
	".claude/settings.local.json"
)
installed="$HOME/.claude/plugins/installed_plugins.json"
known="$HOME/.claude/plugins/known_marketplaces.json"

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
