---
name: claim-audit
description: Audit the claims that justify what is NOT in the code — impossibility, unreachability and sufficiency arguments in doc comments. Use before a milestone merges, after a code review rather than instead of one, or when a doc comment explains why something cannot be done.
---

# Auditing the claims that justify an absence

**This is not a code review.** Run it *after* one, on the same code. A review
examines what is there. This examines the sentences arguing for **what is not
there**, which a review structurally cannot see: an absence has no lines in a
diff.

`docs/decisions.md` §16.10 is why this exists. Twice in one milestone a real
defect survived a green suite *and* an adversarial review because it arrived
carrying its own written explanation of why it was fine:

- *"no ordering of the arithmetic gets that back"* — true of orderings, silent
  about scalings. A representable tangent of `5e307` was being refused.
- *"reachable only by handing `BSplineCurve::new` a net near the ends of the
  `f64` range on purpose"* — reachable through the public API. A representable
  tangent of `-4.76e300` was being refused.

The reasoning attached to each read as evidence of care. A bare `TODO` invites
scrutiny; a well-written paragraph explaining why something cannot be done
deflects it, in proportion to how well written it is.

## Build the inventory

The markers are few and grepping is cheap. A whole crate holds a dozen or two.

```
cannot · never · always · no ordering · nothing · only · impossible
unreachable · by construction · rules out · suffices · is enough
covers · reachable only · no consumer · deferred · not needed
```

Search doc comments and module comments, not just code. Discard the ones that
merely describe present behaviour (`only a plane answers this`). Keep the ones
that **argue for an absence** — a fix not written, a case not handled, a part not
built.

## The three species

Sort each claim, then ask its question. The question is never "is the reasoning
sound?" — locally valid reasoning can still answer the wrong question, which is
exactly how both defects survived. Ask instead: **what would have to be true for
this to be wrong, and is it?**

| Species | Sounds like | Ask |
|---|---|---|
| **Impossibility** | "no ordering helps", "there is no way to reach it" | Is the named family of fixes the only family? |
| **Unreachability** | "nothing in the kernel builds that", "only on purpose" | Is it reachable through the **public API** at all? |
| **Sufficiency** | "one guard is enough", "by construction", "covers every case" | Enumerate what it ranges over. Which member is uncovered? |

**Impossibility.** The claim names a family and rules it out. Your job is the
families it did not name: scaling, reassociation, a different algebraic form, a
wider intermediate, splitting into cases, an exact or compensated technique,
solving a rearranged problem. Breaking the claim means **exhibiting the technique
that works**, not doubting the claim.

**Unreachability.** "No caller does this today" is a statement about today's
callers. If a checking constructor accepts the input, it is reachable. Build it
and see.

**Sufficiency.** The milestone's most serious bug was a relative error bound
whose precondition was enforced in two of the three places it was needed. List
every input the guarantee depends on, then check each is actually guarded.

## Limit or gap

Respect this distinction; it is what keeps the audit from generating noise.

- A **limit**: the answer genuinely does not exist under the constraints — a
  derivative past `f64::MAX`, a knot vector the kernel refuses. Correct. Leave it.
- A **gap**: the answer exists and the arithmetic could not reach it. A defect,
  whatever the doc comment says about consumers.

`CLAUDE.md`'s "no named consumer, no build" governs **features, not correctness
gaps**. Deferring a part nobody needs is that rule working. Deferring a case
where a representable answer is refused is that rule being used as cover.

## Rules

- **Prove or break every finding.** `CLAUDE.md` rule 5. A finding needs a
  concrete input that demonstrates it, or the exact step of an argument that does
  not hold. "This might be wrong" is noise.
- **Do not modify the repository.** Copy a file to a scratch directory to mutate
  it. Never `git stash`, never `git checkout --`, never commit.
- **Report honestly if everything held up.** That is a real result about the
  method and worth more than a list of quibbles.

## Report

1. **Inventory** — count by species, with the `file:line` list.
2. **Findings**, most serious first: the claim as written, why it is wrong, the
   input or technique that breaks it, and gap-or-imprecise-sentence.
3. **Checked and sound** — which you tried hardest to break, and how.
4. **Was this worth running?**

### Numbering the findings

**Label every finding, and use the label everywhere it is discussed afterwards.**
A finding travels: it is reported, argued about, fixed in a commit, and answered
by the user, often across sessions. Prose descriptions do not survive that trip —
"the hole" and "the false claim" both meant something precise for about an hour.

The label is a **letter and a number**:

- **Run as a lane, use the lane's letter.** Lane K's findings are `K1`, `K2`,
  `K3`, `K4`. That letter is the first thing asked about a finding, and it is
  free.
- **Run outside a lane, use `A`.** `A1`, `A2` — `A` for audit, so audit findings
  never collide with a grilling round's `Q1`, `Q2` in the same conversation.

A finding that needs the user to decide something also goes in the session's
`open-questions.md` under the same label, one line, per `CLAUDE.md`. The status
line reads the labels from there, so a finding you numbered is a finding the user
can see is still open.

## Fixing what it finds

A finding resolves one of two ways, and both are cheap:

- The claim is wrong → fix the code, and the test is the input that broke it.
- The claim is right but overstated → **rewrite the sentence** to say what is
  actually true. "No ordering helps" should have read "reordering cannot help,
  because every route needs this subtraction" — which invites the next question
  instead of closing it off.
