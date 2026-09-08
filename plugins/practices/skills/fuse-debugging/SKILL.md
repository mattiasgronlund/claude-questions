---
name: fuse-debugging
description: Debug a fuse that gives the wrong answer or no answer. Use when Model::fuse returns Undecidable, ResultIsNotManifold, ArgumentIntersectsItself or one of the named curved refusals; when a fuse panics; when a union, intersection or difference comes back with a missing face, a face too many, or the wrong volume; when commutativity, associativity, idempotence or absorption fails in fuses_that_must_agree.rs; or when the same pair fuses differently depending on the order of its arguments.
---

# Debugging a fuse

## Look it up before you debug it

`docs/decisions.md` **§39.4 is every refusal the fuse can produce**, thirty-three
rows, each classified **limit** or **gap** with a named test. §38.6 and §30.5 are
the earlier passes.

If your refusal is in that table, the question is not "why does it refuse" — that
is answered — but "has something changed since it was classified". That is a
different and much shorter investigation. Read the table first, every time.

Two things the table tells you that nothing else will: which refusals are
**tolerant-proof** (a `Policy::tolerant` refuses them too, so reaching for a
budget is wasted work — a ball with a pipe through it, two coincident curved
faces, a block corner exactly on a bar), and which are marked
**undemonstrated** — seven rows named and classified with no test behind them.
A refusal from an undemonstrated row is the one worth stopping on.

## The pipeline, and what goes wrong where

```
Model::fuse                        fuse/mod.rs
  fused_under
    Scratch::split_both_groups
      bake                         fuse/bake.rs      inputs flattened out of the arena
      cuts::gather                 fuse/cuts.rs      where each pair of faces meets
      split_a_face × every face    fuse/arrange.rs   cut lines → pieces
    choose                         fuse/select.rs    which pieces the rule keeps
    assemble                       fuse/assemble.rs  pieces → edges → shells → solids
    wobble check                   fuse/mod.rs       what was approximated, against the policy
    commit                         the one mutation, and it cannot fail
```

Everything before `commit` runs in scratch. An `Err` leaves the model
byte-identical, so a failing fuse has left you nothing to inspect — the state you
want was in scratch and is gone. That is what makes this engine expensive to
debug and why the first move is never to read code.

## Start from the error

| What came back | Stage | First thing to look at |
|---|---|---|
| `ArgumentIntersectsItself` | `cuts` | One input crosses itself. Check the *input*, not the fuse — this is noticed here for free rather than by `validate` (§17.4). |
| `Undecidable` | any | Read the records; they name the predicate. Then §39.4, then "A refusal" below. |
| `ACrossingThisCannotBeOrderedAlong`, `TwoCurvesTouchWithoutCrossing`, `AClosedEdgeOfTheAnswerWouldStartAtAPole`, `ACurvedFaceGoesRightRoundWithNoSeam`, `ACurvedEdgeThatIsPartOfACrossingCannotBeNamed` | `arrange` / `assemble` | All in §39.4 with a classification and a named test. Do not re-derive them. |
| `ResultIsNotManifold { count }` | `assemble` | An edge got `count` faces. Almost always selection kept a piece it should not have, or dropped one it should have — look at `select`, not `assemble`. `count: 1` is **live**, not withdrawn — 83 268 fuses found it in two families, turned pairs and a trio fused two-against-one, and `tests/an_edge_with_one_face_along_it.rs` pins it. §48 corrects §38.6 and §39.4. Its sharpest form takes no curve and no rounding: three axis-aligned boxes on the integer grid where the solid that contributes nothing turns an answer into a refusal. |
| `Invalid::FacesDoNotAgreeWhichWayTheyFace`, `Invalid::VolumeIsNotPositive` | `assemble` | **Not about arithmetic.** This is the crate saying it cannot assemble what it cut, before writing anything. |
| a panic in `arrange` | `arrange` | A broken internal invariant: a cell both inside and outside the face, a piece with fewer than three sides, a hole in no piece. Go to "An assert where a refusal belonged". |
| the wrong answer, no error | `select` | Nearly always. `assemble` fails loudly; `select` fails quietly. |

`ResultIsNotManifold` pointing at `select` rather than `assemble` is the one that
costs people a pass. `assemble` is where an edge with three claimants is
*discovered*; it is rarely where it was created.

## Reproduce it as a test before you form a hypothesis

Not as a scratch binary and not as a hand-written pair of solids. The corpus
generators in `crates/rcad-topo/tests/pairs/mod.rs` are what the property suites
draw from, and a repro built from them shrinks, re-runs, and lands as the
regression test the fix needs anyway. A hand-written pair usually differs from
the failing one in some way you have not noticed, and then you debug the wrong
shape.

If a property found it, the seed is already checked in
(`*.proptest-regressions`) — run that file and let proptest shrink. If a soak
found it:

```
RCAD_SOAK_FACTOR=100 RCAD_SOAK_SEED=<seed> cargo nextest run -p rcad-topo --no-capture <test>
```

and put the seed in the regressions file before you start fixing.

## Instrumenting

There is no tracing facility yet, so this is a temporary `eprintln!` at one of
four places, in this order of usefulness:

1. `select::choose` — per piece: which piece, which face, kept or dropped, and
   the `Containment` that decided it. This answers most wrong-answer bugs.
2. `assemble` — per edge: its two corner *names* and how many faces claimed it.
3. `arrange::split_a_face` — per face: how many cut lines went in, how many
   pieces came out.
4. `cuts::gather` — per pair: whether a meet was found, and both ends'
   enclosure widths.

Print names, not coordinates: a corner is either an input vertex or the three
planes it is the meet of, sorted. That is what the engine joins on, and printing
coordinates instead invites you to compare them, which is the bug two sections
down.

Remove them before committing.

## A refusal

Read the records first — predicate, `Level`, outcome, enclosure. Then §39.4.
Then, if it is genuinely new, the `numerical-refusal` skill has the limit-or-gap
procedure and the rescale test.

The short version: a **limit** is an answer that does not exist, and a **gap** is
an answer that exists in `f64` that the arithmetic could not reach. §39.4's own
proportions are the useful prior — the overwhelming majority of rows are gaps.
Assume gap until you can demonstrate otherwise, not the reverse.

## Bug classes this engine has actually had

All five from §38, which is the lane that closed them:

**An assert where a refusal belonged** (§38.2). Two arcs lying on top of each
other hit an assert; coincident input is *data*, not a broken invariant. Panic on
a broken internal invariant, return `Err` on anything a caller could have handed
you. When you see a panic in `arrange`, the first question is whether the
invariant it asserts holds for coincident and degenerate input — not whether the
caller was wrong.

**The uncut case** (§38.1). A solid that nothing cuts must come back as itself.
Easy to break while changing how pieces are gathered, and the property suites do
not always draw a pair where one side is untouched. Check it by hand.

**Degenerate direction** (§38.3, §38.4, §38.5). A closed edge starting at a pole
has no direction; a closed edge has one corner, not two; a chord is not the arc
it spans. Anything asking "which way does this go" or "what are its two ends"
needs an answer for all three.

**A corner left in the middle of a straight edge.** `assemble` folds pieces on
one plane into one face and drops the corners that stop being corners
(`join_up_what_is_one_face`). If a change leaves one behind, the fuse *succeeds*
and hands back a solid the next fuse cannot read — a corner mid-edge has two
planes round it, not three, so it cannot be re-derived. This fails one fuse later
than the change that caused it. Suspect it whenever a second fuse on a first
fuse's output fails and the first output looks fine.

## Three ways to make it worse

**Do not process cut lines one at a time.** `arrange` takes every line cutting a
face at once, and the cut planes are sorted into a canonical order on the way in,
so the pieces are a function of the face and the *set* of planes. Handling lines
one after another makes the pieces depend on argument order and breaks
commutativity and associativity by construction (§17.4). Any fix shaped like
"handle this line first" is wrong even when it makes the failing test pass.

**Do not compare coordinates.** Two pieces meet when they *name* the same corner.
Two faces solving the same three planes in a different order round differently,
so comparing what they rounded to either misses a join or invents one. A
tolerance here is not a smaller version of the right fix; it is a different,
wrong one.

**Do not relax the manifold rule.** An edge used by exactly two coedges is what a
`Model` *is*. Changing it changes the data model, not the behaviour of one
boolean (§17.4).

## Before it is done

- The repro from the corpus generators is a committed test that fails without the
  fix and passes with it.
- `cargo nextest run -p rcad-topo` — in particular `fuses_that_must_agree.rs`,
  which compares answers bit for bit with no tolerance anywhere, and
  `turning_a_fuse.rs`.
- `degenerate_fuses.rs`, `degenerate_curved_fuses.rs` and `when_it_cannot_tell.rs`
  if the fix touched a refusal path at all.
- A soak at `RCAD_SOAK_FACTOR=100` on the suites nearest the change.
- **If a row of §39.4 moved — a refusal gone, a new one, a limit that turned out
  to be a gap — edit §39.4.** A refusal catalogue that drifts from the code is
  worse than none, because the next reader will trust it.
- `just gate`.
- If the fix leaves a doc comment saying something cannot be done or cannot be
  reached, run the `claim-audit` skill on it.
