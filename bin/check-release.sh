#!/usr/bin/env bash
# The "Releasing" steps in README.md, as far as a tree can show them: the three
# plugin versions and every `@vX.Y.Z` in the README name one version, and a tag,
# when one is named, names it too.
#
#     check-release.sh             the tree agrees with itself
#     check-release.sh v0.3.9      and with the tag about to be cut, or just cut
#
# Without the argument it catches a bump that moved one plugin and not the
# others, which is how six of the eight tags after v0.2.3 went out. The other
# two bumped nothing at all, and only the tag's own name can show that.
set -uo pipefail

root=$(dirname "$(dirname "$(readlink -f "$0")")")
tag=${1:-}

version_of() {
  jq -er .version "$root/plugins/$1/.claude-plugin/plugin.json" ||
    { echo "check-release: plugins/$1 has no readable version" >&2; return 1; }
}

want=$(version_of guardrails) || exit 1
status=0

for plugin in questions practices; do
  got=$(version_of "$plugin") || exit 1
  if [ "$got" != "$want" ]; then
    echo "check-release: $plugin is at $got and guardrails at $want" >&2
    status=1
  fi
done

install='^claude plugin marketplace add mattiasgronlund/claude-questions@v[0-9]+\.[0-9]+\.[0-9]+$'
installs=$(grep -cE "$install" "$root/README.md")
if [ "$installs" != 1 ]; then
  echo "check-release: README.md has $installs install lines naming a version, not one" >&2
  exit 1
fi

while IFS=: read -r line pin; do
  if [ "$pin" != "@v$want" ]; then
    echo "check-release: README.md:$line says $pin and the plugins are at $want" >&2
    status=1
  fi
done < <(grep -noE '@v[0-9]+\.[0-9]+\.[0-9]+' "$root/README.md")

if [ -n "$tag" ] && [ "$tag" != "v$want" ]; then
  echo "check-release: the tag is $tag and the plugins are at $want" >&2
  status=1
fi

if [ "$status" != 0 ]; then
  exit 1
fi
echo "check-release: $want in all three plugins and the README${tag:+, and $tag names it}"
