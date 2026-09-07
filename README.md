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
plugins/questions/                 one plugin, so far
  .claude-plugin/plugin.json
  bin/questions.py                 the parser: sessions, find, labels, entry,
                                   compact, json, check
  bin/selftest.sh                  20 cases, no dependencies
  skills/asking-questions/         how to write a question, and what breaks
```

## Installing

The marketplace is a **directory** source, which matters: a directory-source
marketplace runs its plugins in place rather than copying them to a
version-stamped path under `~/.claude/plugins/cache`. That is what lets a
`justfile` in another repo name the parser and keep naming it across version
bumps.

```
/plugin marketplace add ~/git/mattiasgronlund/claude-questions
/plugin install questions@mattiasgronlund-local
```

## Consuming it from a repo

Both callers resolve the plugin through one overridable variable, so no
absolute path is written into a tracked file:

```bash
# .claude/statusline.sh, reduced to a wrapper
plugin=${CLAUDE_QUESTIONS_PLUGIN:-$HOME/git/mattiasgronlund/claude-questions/plugins/questions}
```

```just
# justfile
questions_plugin := env_var_or_default("CLAUDE_QUESTIONS_PLUGIN", \
    home_directory() / "git/mattiasgronlund/claude-questions/plugins/questions")
```

`$HOME`-relative rather than `/home/mattias`, so a clone elsewhere still works,
and `CLAUDE_QUESTIONS_PLUGIN` overrides it for anyone whose layout differs.

## Checking it

```
plugins/questions/bin/selftest.sh
```

No toolchain, no package manager, no network — `python3` and `bash`. That is
deliberate: `rcad` pins everything through `mise` because it builds a Rust
workspace, and this repo builds nothing. It is also why CI here can go green,
which `rcad`'s never has.
