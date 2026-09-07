---
name: testing
description: Write, place and judge a test in rcad. Use when adding a test for a change or a bug fix, when choosing where it goes, when picking what to check an answer against, when adding or extending a generator, when a property passes but you are unsure it proved anything, when a doc comment publishes a bound, when running a soak, or when naming a test.
---

# Testing in rcad

## Where it goes

| What you are testing | Where | Copy from |
|---|---|---|
| One module's logic | `#[cfg(test)] mod tests` in that file | `predicates/src/decision.rs` |
| A published bound, an invariant, a rule over a range of inputs | `crates/<crate>/tests/<a sentence>.rs` | `crates/rcad-topo/tests/fuses_that_must_agree.rs` |
| Something the public API must do | the same, in `crates/rcad/tests/` | `crates/rcad/tests/what_the_facade_calls_a_failure.rs` |
| An example a reader should see | a doc test — `just test` runs them | `predicates/src/lib.rs` |
| The shapes a suite draws from | `tests/<family>/mod.rs` beside it | `crates/rcad-topo/tests/pairs/mod.rs` |

Roughly half the tests are outside the crate on purpose: a suite that can only
reach the public API cannot pass by reaching past it.

## Pick the oracle before you write anything

In order of preference. Take the strongest one available.

| Oracle | Use when | Example |
|---|---|---|
| **Exactly true** | the answer is a whole number and the arithmetic reaches it with no rounding | lattice generators; the fuse comparisons are bit-for-bit because of this |
| **Closed form** | there is a formula for the true answer | a plane-sphere crossing is a circle with a known centre and radius |
| **Exact rational** | the true answer needs arithmetic `f64` does not have | `rcad-geom/tests/support/rational.rs` — de Boor in checked `i128` with gcd |
| **Differential** | an independent implementation exists and is trustworthy | `orient2d_matches_robust.rs` against the `robust` crate |
| **A published bound** | the answer is approximate but the doc comment says by how much | `evaluating_a_spline_stays_inside_its_published_bound.rs` |
| **Two runs that must agree** | nothing knows the right answer, but two ways of asking must match | `fuses_that_must_agree.rs`, `turning_a_fuse.rs` |

**A tolerance is not an oracle.** If you are about to write `< 1e-9`, ask which
row above you skipped. Usually the answer is the first one, and the fix is a
generator on the integer lattice rather than a looser assertion — that is why
`fuses_that_must_agree.rs` can compare face planes and wire rings bit for bit
and say so in its header.

If an exact case outgrows `i128` and the checked arithmetic fails loudly, the
answer is a **smaller case, never a looser assertion**.

## The anti-vacuity rule

The most important section here. A green test that could not have failed is
worse than no test, because it looks like coverage.

Every property that hands back `Ok(())` when an operation refuses **must count
what it actually did and assert a floor.** The existing shapes:

```rust
tally.meaning_to_compare();     // before the first call the comparison needs
tally.comparing();              // when both sides came back with answers
tally.report_what_it_compared("commutativity, lattice pairs");
                                // prints, then asserts the floor
```

and its siblings: `enough_of_them_crossed()`, and the control rows whose whole
job is that one refusal is one bug.

Three ways a suite goes vacuous. Check for all three:

1. **Everything refused.** The property returned `Ok` every time. Counted by the
   floor above.
2. **Everything came back the same uninteresting answer.** A regression making
   every crossing return `Nothing` leaves every refusal count at zero and every
   row green. So each row also insists a real share of its inputs came back
   naming something.
3. **The two runs took the same path.** Two runs down the same branch prove
   nothing however pretty the algebra. Where a test's argument depends on two
   runs differing — the scaled retry, the turned pair — it must *measure* that
   they differed and report that it was not testing anything if they did not.
   `scaling_a_predicate_must_not_change_its_answer.rs` does this explicitly.

## Generators

Four rules, each of which was paid for:

**Build the shape directly, never filter.** No `prop_filter_map(… .ok())`. A
suite that keeps only the inputs that were accepted cannot see a valid input
being *wrongly refused* — the half that caught `ProfileBuilder` turning away a
right triangle (§12.3). End in an `expect`, so a generated shape the kernel
rejects fails the run.

**Several families, reported separately, never blended into one percentage**
(§17.7). At least one must be a **control** that is exactly representable end to
end, where `Policy::certified()` must decide everything and one refusal is one
bug. Without a control, a rate cannot tell a timid filter from genuine
undecidability.

**A second family for what the first cannot draw.** The notched star's corners
sit at increasing angles, so no two edges ever have overlapping bounding boxes —
a self-crossing check that confused "these boxes overlap" with "these edges
cross" passed every property and refused a plain triangle. That is why
`a_simple_polygon` exists. Vary what the family *cannot vary*, not just more of
what it can — the knots in the spline families are not all small whole numbers
for the same reason.

**Shrink parameters, never coordinates.** A `Vec<[f64; 2]>` strategy shrinks
toward a degenerate polygon that is degenerate for an uninteresting reason, and
teaches nothing. Generate arm counts, hole counts, extensions — things that
shrink toward the smallest interesting shape.

**Do not share a generator between suites** (§13 rule 5). Two suites that can go
green together for the same wrong reason are one suite. Sibling generators that
draw different shapes are right; an extension of another suite's generator is
not. Sharing an *oracle* is fine and better than duplicating it — one place to
be wrong, and a mistake makes both suites fail together, which is louder.

## Names

A test name is the claim, as a sentence, in words anyone knows:

```
a_profile_too_big_for_f64_to_multiply_is_normalised_rather_than_refused
three_planes_meeting_at_a_point_cannot_be_decided_in_f64
every_turned_quartic_crossing_that_refuses_was_exactly_tangent_before_the_turn
```

Not `cascade_escalates_on_non_conforming_input_manifold`. The file header says
why the test is not a tautology and cites the decisions.md section it comes
from; that argument is part of the test.

## Bounds and claims

**A published bound needs a test** (§15.6). If a doc comment says an answer is
within some multiple of something, a suite must find the worst case and check it
against that number — and also check the worst case is not *zero*, or the bound
is untested from the other side.

**A claim that something cannot be done or cannot be reached needs a
demonstration and not a paragraph** (§16.10). Same rule. Run `claim-audit`.

## Soak

The shipped corpus runs on every commit and is small on purpose. To search
harder:

```
RCAD_SOAK_FACTOR=100 cargo nextest run -p rcad-topo --release --no-capture <test>
RCAD_SOAK_FACTOR=100 RCAD_SOAK_SEED=<seed> ...     # to re-run one
RCAD_SEARCH_SAMPLES=10000000 cargo test --release -- --nocapture   # the predicate searches
```

A soak is a **different corpus**, so its numbers are not the shipped numbers and
thresholds judged on the shipped corpus stay judged there. When a soak finds a
case, put the seed in the `.proptest-regressions` file next to the suite before
you start fixing.

## Before it is done

- The test fails without the change and passes with it. Check the first half by
  actually running it against the unfixed code — not by reasoning that it would
  fail.
- It is in the right place, drawing from the right family, with an oracle from
  the top of the table you could reach.
- It counts what it did, if it can pass by doing nothing.
- If you could not fix the bug this session, leave a compiling
  `#[ignore = "open: …"]` repro rather than a paragraph describing it.
- `just default`.
