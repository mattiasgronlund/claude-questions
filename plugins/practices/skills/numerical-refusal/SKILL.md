---
name: numerical-refusal
description: Work out why the arithmetic gave up, and whether it was right to. Use when a predicate returns Decision::Undecidable, when an operation returns Error::Undecidable, when a certified policy refuses something it looks like it should decide, when a refusal rate moves, when a filter might be certifying a sign it has not earned, when coordinates are very large or very small or spread far apart, or when you are tempted to introduce a tolerance to make a refusal go away.
---

# When the arithmetic gives up

## The one thing to get right

Every predicate returns a `Decision` with four cases, and the fourth is
`Undecidable { enclosure }`. **At the predicate level that is a result. At the
operation level it is a failure** — `Error::Undecidable`, carrying the records.
Keeping the two apart is the whole design (§2.1, §4.1).

So a refusal is never on its own a bug, and never on its own correct. The
question is always the next one.

## Limit or gap

- A **limit**: the answer does not exist. Refuse, and defer.
- A **gap**: the answer exists in `f64` and the arithmetic could not reach it.
  Fix it.

§16.10 exists because a representable answer was once refused with the sentence
"no ordering of the arithmetic helps" — which was true of orderings and silent
about scalings. Before you write that a refusal is a limit, name the family of
fixes you considered and say why that family is the only one.

**The concrete test, for the commonest case.** These predicates subtract first
and multiply the differences afterwards, so what has to be in range is the
*differences*, not the coordinates. Ask whether one power of two brings them all
in:

- Uniformly enormous, or uniformly tiny → **gap**. One exponent fixes it, and
  `orient2d`/`orient3d` already retry that way. `when_it_cannot_tell.rs` has the
  demonstration: a parallelogram at `1e200` is normalised and built, not refused.
- Coordinates far from the origin whose *differences* are far below it →
  **limit**. Lifting the differences off the bottom pushes the coordinates past
  the top; no single exponent does both, so there is no scaled copy. The reasoning
  is written out in `power_of_two.rs`.

The rescale is only worth anything because it is **exact**: a scaled copy that
lost bits describes different geometry, and a sign proved about that says nothing
about the input. Every result is checked for being normal, and one that is not
sinks the attempt.

## The cascade, and where each level lies to you

1. **`f64` with a forward error bound.** Settles almost everything.
2. **Interval arithmetic.** Sign proved if the enclosure avoids zero.
3. **Exact expansion arithmetic.** Always decides — *for exact `f64` inputs*.

Two failure modes worth knowing before you go looking:

**Level 1's bound is relative, and relative bounds have a precondition.** The
analysis assumes each rounding costs a fixed fraction of the number rounded.
That holds for `+` and `-` on any two `f64`. For `*` it holds only while the
product stays out of the subnormals — down there a product loses an *absolute*
amount, up to half of `2^-1074`, which can be the whole of its value. Feed that
into a relative bound and the filter certifies a sign it has not earned, possibly
the wrong one. This is a real bug in the `robust` crate, `product_is_normal` is
the guard against it here, and
`scaling_a_predicate_must_not_change_its_answer.rs` is the search that finds it.
If you touch a level 1 bound, that suite is the one that matters.

**Level 3 only saves you for inputs that are exact.** A point built by
intersecting three planes is known to lie in a box and nothing recovers what was
never there — that is where `Undecidable` comes from, and no amount of precision
removes it. The exception that matters: a box collapsed onto one `f64` triple
*is* that triple, and `as_exact_as_it_is` says so. Without it, a lattice-aligned
model would refuse decisions it can prove, and the control families whose
expected refusal rate is zero would refuse everything. If a control family starts
refusing, look there first.

## Reading a ProvenanceLog

`Error::Undecidable` carries records. Each `Record` gives you the predicate name,
the `Level` it reached, the outcome, the `enclosure`, the `Measures`, and
`wobble(working_size)`. Read them before you read any code:

- **Which predicate.** Names the stage.
- **Which level.** Stopping at `Float` or `Interval` on input that is exactly
  representable is suspicious — level 3 should have taken it.
- **The enclosure width.** A wide one is genuine uncertainty; one a few ulps
  wide on exact input is usually a filter that gave up early.
- **The `Cause`,** if there is an `Approximation`: `ConstructedPoint` is the
  honest one, `UndecidableResolved` and `TolerantFallback` mean a tolerant
  policy stepped in.

**A fully certified operation logs nothing.** An empty log is the signal that
nothing was fudged (§5). If a certified run has records in it, that is the bug,
whatever else is happening.

## Policy

`Policy` travels as an explicit argument. Never a field on `Model`, never
thread-local — a model whose state silently changes results is the footgun this
kernel exists to avoid (§2.6).

- `Policy::certified()` — `max_wobble()` is exactly zero. Undecided stays
  undecided.
- `Policy::tolerant(scale)` — a budget worked out from the working size. Ten
  times the part, ten times the slack, and nothing else moves it.

An enclosure is **not** comparable against the budget directly.
`Measures::wobble_of` converts it, and that conversion is the only place a
predicate's degree enters (§15.3). An `orient2d` enclosure is an area; the budget
is a length. Comparing them raw is a units error that will look like it works.

One budget covers both a single decision and a whole operation's worst wobble,
which is what stops an operation refusing a solid built out of decisions it
already accepted one at a time.

## Rules

**Never add a tolerance to make a refusal go away.** That is not a smaller
version of the right fix, it is a different and wrong one. The right fixes are: a
better filter, an exact level that reaches further, or an exact rescale.

**Never let `Undecidable` land in a catch-all match arm.** `Decision` is
`#[non_exhaustive]`, so code outside the crate needs a last arm; that arm must
not be where refusals go to die. Match the four cases.

**Never compare an enclosure against a budget without `wobble_of`.**

**A refusal you decide is correct still needs a demonstration**, not a paragraph
— a test that shows the answer does not exist. Run the `claim-audit` skill on
what you wrote.

## Before it is done

- The control families still refuse nothing. A refusal in a family where every
  coordinate is exactly representable is a bug in our filters, not a fact about
  geometry.
- `cargo nextest run -p rcad-predicates`, plus
  `scaling_a_predicate_must_not_change_its_answer.rs` if a bound moved.
- `when_it_cannot_tell.rs` if the change touches what refuses and what does not.
- A soak (`RCAD_SOAK_FACTOR=100`) on the nearest measured suite.
- If a refusal rate moved, say which way and why. A rate going *down* is a
  result worth reporting, not a silent improvement.
- `just gate`.
