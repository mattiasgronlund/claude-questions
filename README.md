# claude-questions

Shared Claude Code tooling for `rcad` and `rscene`, as a local plugin
marketplace.

## Why this exists

The two repos kept copies of the same `.claude/` files, and a copy goes stale.
On 2026-09-07 `rscene`'s status line still had `if (match(...))` where `rcad`
had `while` — so on an entry carrying two labels it printed

```
❓ Q7, Q12          rscene, with Q11 silently dropped
❓ deadbe Q7, Q11, Q12   rcad, after the fix
```

The fix had landed in `rcad` months earlier and never reached `rscene`, which
had seven question files being read by the broken copy. Nothing noticed, because
a miscount reads exactly like a correct count of a different number.

`rcad`'s `docs/decisions.md` §63 records the parser rewrite this repo carries,
and §63.7 named this extraction as the stage that follows it.

## Layout

```
.claude-plugin/marketplace.json    the marketplace, named mattiasgronlund-local
plugins/questions/
  bin/questions.py                 the parser: sessions, find, labels, entry,
                                   compact, json, check
  bin/statusline.sh                the two-line status line, which calls it
  bin/selftest.sh                  20 parser + 22 status line cases
  skills/asking-questions/         how to write a question, and what breaks
plugins/guardrails/
  hooks/hooks.json                 wires both hooks on install
  hooks/no-in-place-rust-patching.sh
  hooks/context-budget.sh
  hooks/patching-cases.json        24 core cases, repo-neutral paths
  bin/check-declared.sh            are the plugins declared, not just present
  bin/check-declared-selftest.sh   5 cases: it skips where there is no Claude
                                   Code, and only there
  bin/selftest.sh                  those, plus 8 context budget cases, plus
                                   the declaration cases
plugins/practices/
  skills/                          the nine shared skills
```

Three rather than one because a marketplace exists so a repo can enable what it
wants, and because `questions` was installed and working before the other two
were written — renaming it to `shared` on its first day would have cost more
than three manifests do.

## Installing

The marketplace is a **directory** source, which matters: a directory-source
marketplace runs its plugins in place rather than copying them to a
version-stamped path under `~/.claude/plugins/cache`. That is what lets a
`justfile` in another repo name the parser and keep naming it across version
bumps.

```
/plugin marketplace add ~/git/mattiasgronlund/claude-questions
/plugin install questions@mattiasgronlund-local
/plugin install guardrails@mattiasgronlund-local
/plugin install practices@mattiasgronlund-local
```

## Consuming it from a repo

Callers resolve the plugins through overridable variables, so no absolute path
is written into a tracked file:

```bash
# .claude/statusline.sh, reduced to a wrapper — a plugin cannot supply a
# statusLine, so a path in the repo has to exist. It must not become a copy.
root=${CLAUDE_PLUGINS_ROOT:-$HOME/git/mattiasgronlund/claude-questions/plugins}
plugin=${CLAUDE_QUESTIONS_PLUGIN:-$root/questions}
```

```just
# justfile
plugins_root := env_var_or_default("CLAUDE_PLUGINS_ROOT", \
    home_directory() / "git/mattiasgronlund/claude-questions/plugins")
questions_plugin := env_var_or_default("CLAUDE_QUESTIONS_PLUGIN", plugins_root / "questions")
guardrails_plugin := env_var_or_default("CLAUDE_GUARDRAILS_PLUGIN", plugins_root / "guardrails")
```

`$HOME`-relative rather than `/home/mattias`, so a clone elsewhere still works,
and the variables override it for anyone whose layout differs.

### From CI

A runner has no Claude Code to install a plugin into, and `$HOME/git/…` is not
there either, so a repo whose gate runs these scripts has to supply them itself.
Clone the marketplace and point `CLAUDE_PLUGINS_ROOT` at it — the same escape
hatch a `check-plugins` recipe already offers a human whose checkout is
somewhere else:

```yaml
- run: |
    git clone --quiet https://github.com/mattiasgronlund/claude-questions.git \
      "$RUNNER_TEMP/claude-plugins"
    git -C "$RUNNER_TEMP/claude-plugins" checkout --quiet <full commit sha>
    echo "CLAUDE_PLUGINS_ROOT=$RUNNER_TEMP/claude-plugins/plugins" >> "$GITHUB_ENV"
```

Outside the checkout, or it reads as untracked to the repo's own gate. No
credentials: this is the one public repo of the three, settled on 2026-09-08 so
that this clone needs no secret to rotate.

**Pinned by full commit sha, and bumped deliberately.** Unpinned, a push here
turns another repo red with no commit in it, and a green there stops meaning
"this tree passes". What the pin does *not* check is that a human's installed
plugins match it: a repo tests that three directories exist, not which version
they hold, so local and CI can disagree about the plugin half of a gate. That is
a limit rather than a gap — an installed plugin need not be a git checkout, so
there is no version on the local side to compare.

Pin at or above `f5f2f48`, where `check-declared.sh` learned that a machine with
no config directory has no Claude Code to have been told anything. Below it, the
declaration check has no answer available but "never declared" and the gate goes
red on a runner. `rcad`'s `docs/decisions.md` §77 is the record.

### What a repo still keeps

The status line wrapper above, and **its own patching cases**. The shipped 24
use neutral paths, because the hook matches `\.(rs|toml|md)` and a scratch
prefix and has never looked at a crate name — so almost every case turned out to
be repo-*flavoured* rather than repo-specific. What is genuinely a repo's own
goes in an overlay it passes to the runner:

```
guardrails/bin/selftest.sh .claude/patching-cases.local.json
```

`rcad` adds three cases that way; `rscene` twelve, the first of them bumping a
pinned `rcad` rev. An overlay named but missing is an **error**, not an empty
overlay — a repo's own cases quietly not running is the drift this repo exists
to end.

The runner prints core plus overlay as a single number: 24 with no overlay, 27
in `rcad`, 36 in `rscene`. Read out of a repo's gate, that number is not the
count of what ships here — this file said `27 core cases` for a day because it
was copied from `rcad`'s.

Repo-specific *prose* goes in that repo's `CLAUDE.md`, which is where
repo-specific facts already live. `delegating` and `handoff` keep `rcad`'s
concrete `just` recipe names and say they are `rcad`'s: a rule you cannot run is
a rule nobody follows, so the commands stay concrete and the reader is pointed
at their own `CLAUDE.md` for the equivalent. The one paragraph that genuinely
differed — how the compile cache is wired, mise `[env]` in `rcad` and a justfile
`export` in `rscene` — became a pointer instead of a claim.

## Checking it

```
plugins/questions/bin/selftest.sh
plugins/guardrails/bin/selftest.sh [overlay.json]
```

No toolchain, no package manager, no network — `python3`, `bash` and `jq`. That
is deliberate: `rcad` pins everything through `mise` because it builds a Rust
workspace, and this repo builds nothing. It is also why CI here answers in
seconds rather than minutes.

It is not a claim that a consuming repo's cannot go green. This line said
`rcad`'s never had, and on 2026-09-08 run `34266469454` made that false: the
first green on the full `just default` gate, once the clone step above was in
place and one unrelated fault was fixed.
