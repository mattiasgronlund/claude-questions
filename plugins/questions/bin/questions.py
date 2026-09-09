#!/usr/bin/env python3
"""The one parser for `open-questions.md`, read by `just question` and by
`statusline.sh`.

**One parser, because there used to be two.** The label grammar lived in the
justfile and again in `statusline.sh`, kept in step by a comment asserting they
matched. They did not: an entry carrying two labels, `**Q7 / Q11**`, counted as
one, and Q11 sat open and invisible through 2026-09-06 (`docs/decisions.md`
§59.2). A grammar with two implementations has no single answer to "is this
entry open", so this file is the answer and both callers shell into it.

**Never drop a `- [ ]` line.** The awk this replaces skipped any entry whose
label it could not parse — `**handoff Q1**` and `**Q1–Q10**` are both in the
wild today, and both vanished from the count *and* the listing with no
diagnostic. That is §59.2's failure again: the line looked complete and was not.
Anything unparsable is reported as `??` with its line number and counted open.

**No mise pin, and that is deliberate.** CLAUDE.md says never install a tool ad
hoc; this installs nothing. Python is here because it is *faster* than what it
replaces, which is not the direction anyone expects: `just question` spawned one
awk per file and took 368 ms over 30 files against 19 ms for one process, and
even the five-second status line went 27.8 ms to 15.6 ms, because a fork costs
more than an interpreter start.
"""

import glob
import json
import os
import re
import sys
import time

# The em dash is the separator every well-formed entry in the corpus uses. The
# two that do not are the same two whose labels do not parse.
SEPARATORS = "—–-"

ENTRY = re.compile(r"^- \[([ x])\]\s*(.*)$")
HEADING = re.compile(r"^#{1,6}\s")
OPTION_LINE = re.compile(r"^\s*(?:[-*]\s+)?\*{0,2}\(([a-h])\)")
# A letter in parentheses is an option only where a word does not run into it:
# `option(s)` and `transformed(m)` are both in the corpus and neither is an
# option. The range stops at (h) because the largest set anyone has written is
# four, and `(i)` is as likely to be a roman numeral as a ninth choice.
OPTION_MENTION = re.compile(r"(?<![A-Za-z0-9])\(([a-h])\)")
RECOMMEND_CANONICAL = "➡️"
RECOMMEND_LEGACY = re.compile(r"→\s*\*?recommend", re.IGNORECASE)


def main(argv):
    if len(argv) < 2:
        return usage()
    command, args = argv[1], argv[2:]
    if command == "sessions" and len(args) == 1:
        return show_sessions(args[0])
    if command == "find" and len(args) == 2:
        return find_session(args[0], args[1])
    if command == "labels" and len(args) == 1:
        return show_labels(args[0])
    if command == "entry" and len(args) == 2:
        return show_entry(args[0], args[1])
    if command == "compact" and len(args) == 1:
        return show_compact(args[0])
    if command == "json" and len(args) == 1:
        return show_json(args[0])
    if command == "check" and len(args) == 1:
        return check(args[0])
    return usage()


def usage():
    sys.stderr.write(__doc__.splitlines()[0] + "\n\n")
    sys.stderr.write(
        "usage: questions.py sessions <root>\n"
        "       questions.py find <root> <hash>\n"
        "       questions.py labels|compact|json|check <file>\n"
        "       questions.py entry <file> <label>\n"
    )
    return 2


def show_sessions(root):
    """Every session with something open, newest first.

    The hash is the address `just question` takes, because the file is named by
    the session id and only the harness knows it.
    """
    found = []
    for path in glob.glob(os.path.join(root, "*", "*", "scratchpad", "open-questions.md")):
        entries = parse(path)
        count = sum(len(e["labels"]) or 1 for e in entries if e["open"])
        if count:
            session = os.path.basename(os.path.dirname(os.path.dirname(path)))
            slug = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path))))
            found.append((os.path.getmtime(path), session, count, slug.rsplit("-", 1)[-1]))
    for mtime, session, count, repo in sorted(found, reverse=True):
        clock = time.strftime("%H:%M", time.localtime(mtime))
        print("  %-6.6s %3d open  %s  %s" % (session[:6], count, clock, repo))
    return 0


def find_session(root, prefix):
    """The one file whose session id starts with `prefix`.

    A prefix matching two sessions is not a question anyone can answer, so it
    fails rather than picking the newer and looking like it worked.
    """
    matched = [p for p in glob.glob(os.path.join(root, "*", "*", "scratchpad", "open-questions.md"))
               if os.path.basename(os.path.dirname(os.path.dirname(p))).startswith(prefix)]
    if not matched:
        sys.stderr.write("no session under %s starts with %s — try 'just question'\n" % (root, prefix))
        return 1
    if len(matched) > 1:
        sys.stderr.write("%s matches %d sessions:\n" % (prefix, len(matched)))
        for path in matched:
            sys.stderr.write("  %s\n" % os.path.basename(os.path.dirname(os.path.dirname(path))))
        return 2
    print(matched[0])
    return 0


def show_labels(path):
    """One line per entry: its labels, whether it is open, and its heading.

    This doubles as the format check a reader can run without being told to. An
    entry the status line would drop shows up here as `??` rather than as
    nothing, which is the whole point of it.
    """
    for entry in parse(path):
        labels = ", ".join(entry["labels"]) if entry["labels"] else "??"
        state = "open" if entry["open"] else "done"
        heading = entry["heading"] if entry["labels"] else "line %d: %s" % (entry["line"], entry["raw"])
        print("  %-11s %-4s  %.66s" % (labels, state, heading))
    return 0


def show_entry(path, label):
    """One entry in full, addressed by any of its labels."""
    for entry in parse(path):
        if label in entry["labels"]:
            sys.stdout.write("".join(entry["lines"]))
            return 0
    sys.stderr.write("no question labelled %s in %s\n" % (label, path))
    return 1


def show_compact(path):
    """The status line's second line: open labels, consecutive runs collapsed.

    Malformed entries appear as `??×n` — they are open questions that cannot be
    named, and a count you cannot name is still a count you must see.
    """
    entries = parse(path)
    labels = [label for entry in entries if entry["open"] for label in entry["labels"]]
    unnamed = sum(1 for entry in entries if entry["open"] and not entry["labels"])

    segments = [collapse(labels)] if labels else []
    if unnamed:
        segments.append("??×%d" % unnamed)

    print(", ".join(segments))
    return 0


def collapse(labels):
    """Labels with consecutive runs written as ranges: `K1-K4, Q7, Q11`.

    A run of exactly two reads better spelled out than hyphenated.

    It is a function rather than a paragraph inside `show_compact` because the
    TUI composes "I agree on Q1, Q2-Q8" from the same rule. Two callers, one
    implementation — the whole reason this file exists is that a grammar with
    two of them has no single answer to what it means.
    """
    numbers = sorted({split_label(label) for label in labels})

    segments = []
    i = 0
    while i < len(numbers):
        j = i
        while (j + 1 < len(numbers)
               and numbers[j + 1][0] == numbers[i][0]
               and numbers[j + 1][1] == numbers[j][1] + 1):
            j += 1
        letter = numbers[i][0]
        first, last = letter + str(numbers[i][1]), letter + str(numbers[j][1])
        if j == i:
            segments.append(first)
        elif j == i + 1:
            segments.append("%s, %s" % (first, last))
        else:
            segments.append("%s-%s" % (first, last))
        i = j + 1
    return ", ".join(segments)


def show_json(path):
    """The machine-readable view, for anything that wants to consume a file.

    It goes one way on purpose. Questions are written as markdown because a body
    is prose with backticks and `§` refs in it, and escaping that into JSON
    through `Edit` is the quiet-failure shape `docs/decisions.md` §50.8 bans
    heredocs for. Markdown in, JSON out.
    """
    print(json.dumps(parse(path), indent=2, ensure_ascii=False))
    return 0


def check(path):
    """Grammar violations in one file, which is always the caller's own.

    **Scoped to your own file, and that is the whole exemption mechanism.** A
    list of grandfathered session ids would outlive what it names — `/tmp` is
    swept at 30 days, so every id in it dangles within a month — and it would be
    a second record beside the thing itself, which is the shape `decisions.md`
    §60 rejected for the hub. A dead session's file cannot be fixed, so judging
    it produces noise nobody can act on. A live session's can, so it is judged.
    """
    problems = []
    for entry in parse(path):
        where = "line %d" % entry["line"]
        if not entry["labels"]:
            problems.append("%s: no label the reader can parse: %s" % (where, entry["raw"][:60]))
            continue
        name = entry["labels"][0]
        if entry["separator"] not in ("—", ""):
            problems.append("%s %s: heading separator is %r, must be an em dash"
                            % (where, name, entry["separator"]))
        if entry["separator"] == "":
            problems.append("%s %s: no separator between the label and the heading" % (where, name))
        # An answered entry names the letter it chose — `→ answered: **(a)**` —
        # which is an answer and not an offer of options. Judging it flagged
        # every settled question in the file this checker was first run on.
        if not entry["open"]:
            continue
        # Any letter left after the marked ones are subtracted is an option
        # written into a sentence. An entry that marks (a) and leaves (b), (c)
        # and (d) in its prose reads as complete and is not — that is this file,
        # the first time this rule was run against it.
        if entry["mentions"]:
            problems.append("%s %s: options %s are stated in prose but not marked as option lines"
                            % (where, name, ", ".join("(%s)" % o for o in entry["mentions"])))
        expected = [chr(ord("a") + i) for i in range(len(entry["options"]))]
        if entry["options"] and entry["options"] != expected:
            problems.append("%s %s: option letters are %s, must run from (a) with no gaps"
                            % (where, name, ", ".join("(%s)" % o for o in entry["options"])))
        if entry["options"] and not entry["recommendation"]:
            problems.append("%s %s: offers options but recommends none" % (where, name))
        if entry["recommendation"] == "legacy":
            problems.append("%s %s: recommendation uses `→ *recommend`, write `%s`"
                            % (where, name, RECOMMEND_CANONICAL))

    for problem in problems:
        print(problem)
    return 1 if problems else 0


def parse(path):
    """Every entry in a file, in order, including the ones that do not parse.

    An entry runs from its `- [ ]` line to the next one. Two things end it
    early, and both were bugs: a fenced block may contain a `- [ ]` example — it
    is how CLAUDE.md documents this very format — and a `##` section heading
    belongs to the document, not to the entry above it. Ten entries in the
    corpus had a heading glued into them, and the file that first proposed this
    grammar was one of them within a turn of being written.
    """
    entries = []
    current = None
    fenced = False
    with open(path, encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            elif not fenced:
                match = ENTRY.match(line)
                if match:
                    current = new_entry(number, match.group(1) == " ", match.group(2), line)
                    entries.append(current)
                    continue
                if HEADING.match(line):
                    current = None
                    continue
            if current is not None:
                current["lines"].append(line)
    for entry in entries:
        classify(entry)
    return entries


def new_entry(number, is_open, text, raw_line):
    labels, separator, heading = split_header(text)
    return {
        "line": number,
        "open": is_open,
        "labels": labels,
        "separator": separator,
        "heading": heading,
        "raw": text.rstrip("\n"),
        "lines": [raw_line],
        "options": [],
        "mentions": [],
        "recommendation": None,
    }


def split_header(text):
    """The labels, the separator and the heading of an entry's first line.

    The labels are the run right after the checkbox, never the first `Q` seen
    anywhere: a body is free to mention `M5` or `§52.11` without becoming a
    question. One entry may carry several when one answer settles them all, and
    reading only the first is the §59.2 bug.
    """
    rest = re.sub(r"^\*+", "", text.strip())
    labels = []
    while True:
        label = re.match(r"[A-Z]+[0-9]+", rest)
        if not label:
            break
        labels.append(label.group(0))
        rest = rest[label.end():]
        joined = re.match(r"\**\s*/\s*\**", rest)
        if not joined:
            break
        rest = rest[joined.end():]
    rest = re.sub(r"^\**\s*", "", rest)
    separator = rest[0] if rest[:1] and rest[0] in SEPARATORS else ""
    return labels, separator, rest[len(separator):].strip()


def split_label(label):
    """A label's letter and its number, so `K10` sorts after `K9` and not after
    `K1`, and so two letter series stay apart."""
    letter, number = re.match(r"([A-Z]+)([0-9]+)", label).groups()
    return letter, int(number)


def classify(entry):
    """The structured parts of an entry: its options and its recommendation.

    The body between them is free prose the tools carry and never interpret.
    That line is where the grammar stops on purpose — pinning paragraph
    structure too would make writing a question cost what §50.8 is about, and
    only 17 of the 227 entries in the corpus offer options at all.
    """
    for line in entry["lines"]:
        option = OPTION_LINE.match(line)
        if option:
            entry["options"].append(option.group(1))
        entry["mentions"].extend(OPTION_MENTION.findall(line))
        if RECOMMEND_CANONICAL in line:
            entry["recommendation"] = "canonical"
        elif entry["recommendation"] is None and RECOMMEND_LEGACY.search(line):
            entry["recommendation"] = "legacy"
    entry["mentions"] = sorted(set(entry["mentions"]) - set(entry["options"]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
