#!/usr/bin/env bash
# Everything this plugin ships, against its cases.
#
# Three checks and not two: `check-declared.sh` joined the hooks here when it
# grew a skip, and a skip is the one thing that has to be tested from both
# sides. It is the only one that can fail by staying quiet.
#
#     selftest.sh                          the shipped cases only
#     selftest.sh .claude/patching-cases.local.json    plus a repo's own
#
# The overlay is the answer to a question this plugin had to settle before it
# could exist: the cases name file paths, and a path names a repo. Almost all of
# them turned out to be repo-*flavoured* rather than repo-specific — the hook
# matches `\.(rs|toml|md)` and a scratch prefix, and has never looked at a crate
# name — so the shipped set uses neutral paths and a repo adds only what is
# genuinely its own. `rcad` adds two; `rscene` adds one about a pinned rev.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")

"$here/check-patching-hook.sh" "$@" || exit 1
"$here/check-context-budget.sh" || exit 1
"$here/check-declared-selftest.sh" || exit 1
