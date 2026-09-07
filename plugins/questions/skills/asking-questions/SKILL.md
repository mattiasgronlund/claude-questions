---
name: asking-questions
description: Write a question for the user into open-questions.md so the reader, the status line and the checker all agree it exists. Use when asking the user a decision, when running a grilling round, when recording a lane's findings, when marking a question answered, or when `just question-check` reports a violation.
---

# Asking the user a decision

A question exists in two places at once: in the terminal, where the user reads
it, and in `open-questions.md` in this session's scratchpad, where it survives
the turn. Both, the same turn, always. A question asked only in the terminal
scrolls away and costs a full-context turn to recover — that happened, and it is
why the file exists.

The file is never in the tree. Four sessions were live across two repos on
2026-09-05 and a tracked file would have had all four writing to it. Per session
also means the numbering is this conversation's own, so `Q3` means what it says
to the person reading it.

## The shape

```
- [ ] **Q11** — Short heading, in one line?

  The body, as many paragraphs as it takes. Backticks, `§` refs and file:line
  belong here; this is the argument, not a summary of it.

  - **(a)** the first option, on a line of its own
  - **(b)** the second

  ➡️ *Recommend (a), because …*
```

The heading line, the option lines and the `➡️` line are grammar. The prose
between them is yours and no tool reads it.

- **The label is a letter and a number, right after the checkbox.** `Q` for a
  grilling round or any plain decision. A lane's findings take the lane's own
  letter — `K1`-`K4` were Lane K's — because "which lane is this from" is the
  first thing asked about a finding. A body may mention `M5` or `§52.11`
  without becoming a question, because only the run after the checkbox counts.
- **An em dash separates the label from the heading.** 225 of 227 entries in the
  corpus already do; the two that do not are the two whose labels do not parse.
- **Options go on their own lines, lettered from `(a)`, no gaps.** A gap is what
  a dropped option looks like.
- **An entry that offers options recommends one**, on a `➡️` line. Older entries
  say `→ *recommend*` and are still read, but new ones do not write it.
- **One entry may carry two labels** when one answer settles both: `**Q7 / Q11**
  — …`, addressable as either, counted as two.
- **`- [x]` and `→ answered: …`** when the answer comes. Name who answered and
  when; a relayed approval is not an approval.

## Reading it back

`just question` lists the sessions with something open. `just question <hash>`
lists that session's labels and headings, and announces a count of grammar
violations under the listing. `just question <hash> Q11` prints that one entry
in full.

Never `!cat` the file. Shell mode puts every line of it into the conversation
and charges for them on every later turn, which is the cost the status line and
this recipe exist to avoid.

## Checking it

Run `just question-check <hash>` on **your own** file, in the turn you write a
question. It names every violation with a line number.

Nothing else is checked, and that is deliberate. There is no list of
grandfathered sessions: `/tmp` is swept at 30 days so a list of session ids
dangles within a month, and it would be a second record beside the thing itself
— the shape `docs/decisions.md` §60 rejected for the hub. A dead session's file
cannot be fixed, so judging it is noise nobody can act on.

## What breaks, and what it costs

Each of these was live in this tree on 2026-09-07, and each is now a case in
`just check-questions-selftest`:

- **A label that does not parse** — `**handoff Q1**`, `**Q1–Q10**` — used to
  vanish from the count *and* the listing with no diagnostic. It now shows as
  `??` with its line number, and as `??×1` in the status line. A question that
  disappears is the one failure this cannot have (`docs/decisions.md` §59.2).
- **A fenced example in a body** truncated the body at the fence. The format is
  documented as a fenced entry, so an entry quoting the format broke the reader
  showing it.
- **A `##` section heading** was swallowed into the entry above it. Headings
  belong to the document; they end an entry and join no body.
- **Options written into a sentence** cannot be lifted back out of it. Seventeen
  entries offered options and none marked them, which is what made `(a)` hard to
  find.

## The turn itself

Ask in prose, numbered, batched, with the recommendation and the narrowing
spelled out. Do not reach for `AskUserQuestion` for a design batch: it caps at
four questions of four options and would split one message into seven.

End any turn that asks for a decision with a `## Waiting on you` block, last,
after the prose.

The file dies with the session, so carry every unanswered question into the
handoff document. Long argument belongs in `docs/decisions.md` under the section
it will become; the scratchpad file is what is outstanding, not why.
