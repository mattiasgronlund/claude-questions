# claude-questions

Shared Claude Code tooling for `rcad` and `rscene`, as a plugin marketplace
pinned by tag.

The marketplace is still named `mattiasgronlund-local`, from the days when the
only way to reach it was a path on one machine. The name is the identity —
a consumer that says anything else registers nothing, silently — so renaming it
would cost every consumer a re-registration to buy an adjective.

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
  bin/questions-tui.py             read and answer, in a terminal of its own
  bin/selftest.sh                  20 parser + 22 status line + 22 TUI cases
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

Once per machine, and the `@v0.1.0` is the point:

```
claude plugin marketplace add mattiasgronlund/claude-questions@v0.1.0
claude plugin install -y questions@mattiasgronlund-local
claude plugin install -y guardrails@mattiasgronlund-local
claude plugin install -y practices@mattiasgronlund-local
```

Each line is load-bearing, and the following was measured against scratch
config directories on claude 2.1.257 rather than read off a schema:

- **The marketplace name is not the caller's to choose.** It comes from
  `.claude-plugin/marketplace.json`, and an `extraKnownMarketplaces` key that
  disagrees with it registers nothing and says nothing. `marketplace add` has no
  name flag. So both consuming repos know these plugins by
  `mattiasgronlund-local`, and one shared pin is what that name can carry.
- **A committed `extraKnownMarketplaces` entry does not register itself.** Four
  sessions with the entry at user scope and four at project scope left
  `known_marketplaces.json` untouched. The `add` above is what writes it — at
  user scope by default, `--scope project` to write the repo's own settings
  file instead.
- **`enabledPlugins` does not install an externally-sourced plugin either.**
  Registered and cloned, four sessions in a row loaded nothing; the three
  `install` lines made them load on the next.
- **`ref` is a tag or a branch, never a commit.** It is handed to `git clone
  --branch`, so a sha fails with `fatal: Remote branch … not found in upstream
  origin`. A `sha` field is in the documented schema and is silently ignored —
  a fresh clone carrying one still lands on the default branch. That is why the
  pin is a tag.

Two trees end up on disk and they are not interchangeable. The **marketplace
clone**, at `~/.claude/plugins/marketplaces/mattiasgronlund-local`, is the
pinned tree and its path does not move. The **install**, at
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`, is what the session
loads and is version-stamped — so a `justfile` naming it breaks at the next
bump. Recipes read the clone.

### Working on the plugins themselves

A **directory** source runs the working tree in place: no clone, no install
step, and an edit is live in the next session.

```
claude plugin marketplace add ~/git/mattiasgronlund/claude-questions
```

It cannot be pinned, and that is the trade. It is also the escape hatch out of
the shared pin: one repo can try a version the other has not taken by pointing
`CLAUDE_PLUGINS_ROOT` at a checkout, without a second marketplace identity to
keep in step.

## Releasing

One tag for the repo, `vX.Y.Z`, and the three `plugin.json` versions move with
it — so a plugin's own version names the tag it came from. Before this the three
all said `0.1.0` and always had, which is three version strings that mean
nothing.

`claude plugin tag` produces `{plugin}--v{version}`, which is per-plugin and
exists for resolution between plugins. A marketplace `ref` is one ref for the
whole repo, so pinning to a tag named after one of three plugins would say
something untrue about the other two.

## Consuming it from a repo

Callers resolve the plugins through overridable variables, so no absolute path
is written into a tracked file:

```bash
# .claude/statusline.sh, reduced to a wrapper — a plugin cannot supply a
# statusLine, so a path in the repo has to exist. It must not become a copy.
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
clone=$config/plugins/marketplaces/mattiasgronlund-local/plugins
[ -d "$clone" ] || clone=$HOME/git/mattiasgronlund/claude-questions/plugins
root=${CLAUDE_PLUGINS_ROOT:-$clone}
plugin=${CLAUDE_QUESTIONS_PLUGIN:-$root/questions}
```

```just
# justfile
claude_config := env_var_or_default("CLAUDE_CONFIG_DIR", home_directory() / ".claude")
marketplace_clone := claude_config / "plugins/marketplaces/mattiasgronlund-local/plugins"
plugins_root := env_var_or_default("CLAUDE_PLUGINS_ROOT", \
    if path_exists(marketplace_clone) == "true" { marketplace_clone } \
    else { home_directory() / "git/mattiasgronlund/claude-questions/plugins" })
questions_plugin := env_var_or_default("CLAUDE_QUESTIONS_PLUGIN", plugins_root / "questions")
guardrails_plugin := env_var_or_default("CLAUDE_GUARDRAILS_PLUGIN", plugins_root / "guardrails")
```

Three places, in that order: the override, then the pinned marketplace clone,
then a plain checkout. The pin is the default and the working tree is the
exception you ask for — which is the opposite of how it read before there was a
pin to prefer.

`$HOME`-relative rather than `/home/mattias`, so a clone elsewhere still works,
and the variables override it for anyone whose layout differs.

### Reading the questions

`just question` prints them. The TUI reads and answers them, and it is a recipe
of its own because it needs a terminal to itself — run inside a Claude session
it would put everything it draws into the conversation, which is the cost the
status line exists to avoid:

```just
# justfile — run this in a second terminal, never in a session's shell mode
question-tui *hash:
    @python3 {{ questions_plugin }}/bin/questions-tui.py {{ hash }}
```

It never writes `open-questions.md`. It composes the answers into the text you
would have typed, puts it on your clipboard, and you paste it into the session's
own terminal, where it arrives as your turn — see `asking-questions` for why
that last part is not an implementation detail.

### From CI

A consuming repo's CI does not need these plugins, and until 2026-09-09
`rscene`'s cloned them anyway. Asked what the clone bought, each of its three
users turned out to be checking nothing a runner has:

- `check-plugins` asks whether Claude Code has been *told about* three plugins.
  A runner has no Claude Code, and the clone was creating the very directories
  the check then found — a job satisfying its own precondition.
- `check-hooks` tests a **PreToolUse** hook. A hook fires in a session; there is
  no session on a runner, so the cases ran against a hook that could not have
  fired either way.
- `check-questions-selftest` ran *this* repo's suite out of a clone the job
  made, which tests this tree rather than the consumer's.

So the recipes skip where there is no config directory, and say **"skipped, not
passed"** when they do — the predicate `check-declared.sh` already uses. The
scripts stay runnable on a runner for anyone who wants them: point
`CLAUDE_PLUGINS_ROOT` at a clone, outside the checkout or it reads as untracked.
No credentials needed; this is the one public repo of the three, settled on
2026-09-08 so that a clone needs no secret to rotate.

What the consumer genuinely loses is its **own** overlay patching cases —
`rscene`'s twelve — which now run when a human runs the gate and nowhere else.
The shared cases lost nothing and gained a runner: `.github/workflows/check.yml`
here runs `plugins/guardrails/bin/selftest.sh`, which before that day existed
only inside `rscene`'s gate. A suite whose only runner belongs to a repo that
merely consumes it is one decision away from never running again.

`f5f2f48` is where `check-declared.sh` learned that a machine with no config
directory has no Claude Code to have been told anything; below it the check had
no verdict available but a false "never declared". `rcad`'s
`docs/decisions.md` §77 is the record. Every tag from `v0.1.0` on is above it.

### What a repo still keeps

The status line wrapper above, and **its own patching cases**. The shipped 24
use neutral paths, because the hook matches `\.(rs|toml|md)` and a scratch
prefix and has never looked at a crate name — so almost every case turned out to
be repo-*flavoured* rather than repo-specific. What is genuinely a repo's own
goes in an overlay it passes to the runner:

```
guardrails/bin/selftest.sh .claude/patching-cases.local.json
```

`rscene` adds twelve cases that way, the first of them bumping a pinned `rcad`
rev. An overlay named but missing is an **error**, not an empty overlay — a
repo's own cases quietly not running is the drift this repo exists to end.

The runner prints core plus overlay as a single number: 24 with no overlay, 36
in `rscene`. Read out of a repo's gate, that number is not the count of what
ships here — this file said `27 core cases` for a day because it was copied from
`rcad`'s.

`rcad` has **not** migrated. It still runs its own `.claude/hooks/` copies of
both hooks and its own 25-case file, and its `question` recipe is a second
implementation of the parser rather than a call to it — which is exactly the
arrangement that let the status lines drift apart in the first place. Three of
those 25 cases are genuinely `rcad`'s and become its overlay; the rest are the
shared 24 under different names. That migration is the piece of work this one
does not do.

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
seconds rather than minutes. The TUI holds that line too: stdlib `curses`, and
OSC 52 for the clipboard rather than `xclip`, `wl-copy`, `pbcopy` and the
platform matrix that choosing between them needs.

It is not a claim that a consuming repo's cannot go green. This line said
`rcad`'s never had, and on 2026-09-08 run `34266469454` made that false: the
first green on `rcad`'s full gate, once the clone step above was in place and
one unrelated fault was fixed. That run invoked `just default`; the recipe is
`just gate` from `rcad`'s `1af6f1a` the same day, and `rscene`'s is still
`default`.
