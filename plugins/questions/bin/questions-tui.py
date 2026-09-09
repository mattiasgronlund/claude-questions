#!/usr/bin/env python3
"""The reading and answering end of `open-questions.md`, as a program you run.

**It never writes the questions file.** Claude writes it, the way it always
has. A second writer would mean a second implementation of a grammar this repo
went to some trouble to have only one of, and it would race the session that is
appending to the same file in the same seconds. Nothing here opens that file for
writing, so there is nothing to lock and nothing to lose.

**It hands the answers to you rather than posting them.** A session's inbox
socket is documented and would work, and it was the plan for two rounds. The
argument that killed it is that a message arriving that way is a peer message,
and the documentation is explicit about what one is worth: "a message from
another session never counts as your consent". `asking-questions` says the same
thing in its own words — a relayed approval is not an approval. The answers to a
grilling round are consent and nothing else, so they have to arrive as your own
turn. This composes them, puts them on your clipboard, and you paste them into
the session's own terminal.

That choice deleted more than it cost: no socket, no registry parsing, no
`session_id` pinning against a recycled pid, and no delivery outcome to report
that this program could not have observed anyway, because the status frame goes
back to a sender socket it does not have.

**Run it in a second terminal, never as a tool call.** Curses needs the
terminal, and routing this through shell mode would put every line it draws into
a conversation — which is the cost the status line exists to avoid.
"""

import base64
import curses
import glob
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time

# Resolved beside this file rather than through `CLAUDE_QUESTIONS_PLUGIN`, for
# the reason `statusline.sh` gives: the variable is how a repo finds this
# plugin, and once you are inside it the parser is a sibling. Reading the
# variable here would let a wrapper point at one plugin and get another
# plugin's grammar.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import questions  # noqa: E402

AGREE = "agree"
OPTION = "option"
PROSE = "prose"
OPEN = "open"


def main(argv):
    args = argv[1:]
    if args[:1] == ["compose"] and len(args) == 2:
        return show_compose(args[1])
    if args[:1] == ["sessions"] and len(args) == 2:
        return show_sessions(args[1])
    if args[:1] in (["-h"], ["--help"]):
        return usage(0)

    root = os.environ.get("CLAUDE_QUESTIONS_ROOT") or default_root()
    if not root:
        sys.stderr.write("no questions root under %s — is any session live?\n" % tmp_base())
        return 1
    if not sys.stdout.isatty():
        sys.stderr.write("this is a terminal program; run it in a terminal of its own\n")
        return 2
    return curses.wrapper(lambda screen: App(root, args[0] if args else None).run(screen))


def usage(code=2):
    sys.stderr.write(__doc__.splitlines()[0] + "\n\n")
    sys.stderr.write(
        "usage: questions-tui.py [<hash>]        read and answer, interactively\n"
        "       questions-tui.py sessions <root> the picker's rows, as text\n"
        "       questions-tui.py compose <spec>  the text a batch of answers makes\n"
    )
    return code


# --- the pure core: everything that is not drawing
#
# It is separated because this is the half that can be wrong without anyone
# noticing. The bugs this repo has actually had were grammar and counting bugs,
# and every one of them would live in here. `check-tui.sh` drives these two
# subcommands; the curses layer below is meant to be thin enough to read.


def tmp_base():
    return os.environ.get("TMPDIR") or "/tmp"


def default_root():
    """Where the sessions keep their scratchpads, or nothing if none do."""
    for base in (os.environ.get("TMPDIR"), "/tmp"):
        if not base:
            continue
        root = os.path.join(base, "claude-%d" % os.getuid())
        if os.path.isdir(root):
            return root
    return None


def agents():
    """Name, working directory and pid for the sessions this machine knows.

    `claude agents --json` is documented for exactly this — "print active
    sessions as a JSON array and exit (for scripting; does not require a TTY)"
    — and it is preferred over reading `~/.claude/sessions/*.json` because that
    path is not documented and this program has just spent a whole design round
    preferring the supported interface over the one that happens to work.

    It is a name source and not a liveness oracle: it lists sessions that ended
    months ago with `"status": "idle"`. The pid settles that instead.

    Returning nothing is a normal answer. `claude` may not be on the path at
    all, and the caller treats an empty result as "liveness unknown" rather than
    as "everything is dead", so a missing binary hides no questions.
    """
    override = os.environ.get("CLAUDE_QUESTIONS_AGENTS_JSON")
    try:
        if override:
            with open(override, encoding="utf-8") as handle:
                rows = json.load(handle)
        else:
            done = subprocess.run(["claude", "agents", "--json"],
                                  capture_output=True, text=True, timeout=20)
            if done.returncode != 0:
                return {}
            rows = json.loads(done.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    known = {}
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and row.get("sessionId"):
                known[row["sessionId"]] = row
    return known


def alive(pid):
    """Whether a pid is still running, as far as this user can tell.

    A pid we may not signal is somebody else's process and not the session we
    were looking for, so it counts as gone.
    """
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    except (TypeError, ValueError, OSError):
        return False
    return True


def sessions(root, known):
    """Every session with a questions file, newest first.

    The same glob `just question` walks, so the two agree about what exists.
    Each row carries the repo the session was working in — from the agent's own
    working directory when it is known, because the directory slug's last
    segment turns `claude-questions` into `questions` and the header you paste
    should name the repo you would name.
    """
    found = []
    pattern = os.path.join(root, "*", "*", "scratchpad", "open-questions.md")
    for path in sorted(glob.glob(pattern)):
        try:
            entries = questions.parse(path)
        except OSError:
            continue
        if not entries:
            continue
        session = os.path.basename(os.path.dirname(os.path.dirname(path)))
        slug = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path))))
        row = known.get(session) or {}
        cwd = row.get("cwd")
        found.append({
            "session": session,
            "hash": session[:6],
            "path": path,
            "repo": os.path.basename(cwd.rstrip("/")) if cwd else slug.rsplit("-", 1)[-1],
            "name": row.get("name") or "",
            "mtime": os.path.getmtime(path),
            "open": sum(len(e["labels"]) or 1 for e in entries if e["open"]),
            "total": len(entries),
            # Unknown is its own answer. A session `claude agents` never
            # mentioned may be one it cannot see rather than one that ended.
            "live": alive(row["pid"]) if row.get("pid") is not None else None,
        })
    found.sort(key=lambda row: row["mtime"], reverse=True)
    return found


def show_sessions(root):
    """The picker's rows as plain text, which is how they are tested."""
    known = agents()
    for row in sessions(root, known):
        state = "live" if row["live"] else ("dead" if row["live"] is False else "unknown")
        clock = time.strftime("%H:%M", time.localtime(row["mtime"]))
        print("  %-6.6s %3d open  %s  %-16.16s %-16.16s %s"
              % (row["hash"], row["open"], clock, row["repo"], row["name"], state))
    return 0


def compose(session, repo, answers):
    """The text you paste into the session's terminal.

    The shape is the one a person types by hand: one line agreeing with
    everything that needed no argument, with the runs collapsed, and the rest
    named underneath. It is read by a model and never parsed, so a sentence
    that says what you mean beats a sigil that has to be learned.

    "I agree" needs no idea of *which* option was recommended — only that you
    pressed the agree key. Claude knows what it recommended. That is why the
    parser never had to learn to identify a recommended letter, and why the
    recommendation grammar still lives in exactly one place.

    The header names the session because two terminals and a batch of decisions
    is a wrong-window paste waiting to happen, and the labels do not protect
    you: every grilling round in every session is numbered from Q1, so answers
    pasted into the wrong terminal land on questions that have those numbers too
    and read as valid. The session reading this knows its own hash and can
    refuse it.
    """
    lines = []
    header = " — ".join(part for part in (session, repo) if part)
    if header:
        lines += [header, ""]

    agreed = [a["label"] for a in answers if a["kind"] == AGREE]
    differ = [a for a in answers if a["kind"] in (OPTION, PROSE)]
    unsettled = [a for a in answers if a["kind"] == OPEN]

    head = "I agree on " + questions.collapse(agreed) if agreed else ""
    if differ:
        if head:
            lines.append(head + " but:")
            lines += [stated(a, "  ") for a in in_order(differ)]
        else:
            lines += [stated(a, "") for a in in_order(differ)]
    elif head:
        lines.append(head)

    if unsettled:
        if lines and lines[-1]:
            lines.append("")
        lines.append("still open:")
        lines += [stated(a, "  ") for a in in_order(unsettled)]

    return "\n".join(lines).rstrip() + "\n"


def in_order(answers):
    """Answers by label, so K10 follows K9 and two series stay apart."""
    return sorted(answers, key=lambda a: questions.split_label(a["label"]))


def stated(answer, pad):
    """One answer, as `Q3: (c)` or `Q3: whatever you typed`.

    A paragraph keeps its shape: later lines are indented to sit under the
    first, so a long answer still reads as belonging to its label.
    """
    text = (answer.get("text") or "").strip()
    first, *rest = (text.splitlines() or [""])
    out = [("%s%s: %s" % (pad, answer["label"], first)).rstrip()]
    out += ["%s  %s" % (pad, line.strip()) if line.strip() else "" for line in rest]
    return "\n".join(out)


def show_compose(spec_path):
    """`compose` from a JSON spec, which is how the shape above is tested."""
    with open(spec_path, encoding="utf-8") as handle:
        spec = json.load(handle)
    sys.stdout.write(compose(spec.get("session", ""), spec.get("repo", ""),
                             spec.get("answers", [])))
    return 0


def to_clipboard(text):
    """Ask the terminal itself to take the text, with OSC 52.

    Nothing to install, and it survives ssh, which is why it is here rather
    than `xclip`, `wl-copy` and `pbcopy` and the platform matrix that picking
    between them needs. What it cannot do is report failure: a terminal with the
    feature switched off, and several ship that way, silently does not copy. So
    the caller shows the text as well, always, and this never claims a copy it
    cannot verify.
    """
    payload = base64.b64encode(text.encode("utf-8")).decode("ascii")
    sequence = "\033]52;c;%s\a" % payload
    if os.environ.get("TMUX"):
        # tmux passes an escape through only when it is wrapped, and only with
        # `set -g set-clipboard on`. Unwrapped, tmux eats it and the copy is
        # lost without a word.
        sequence = "\033Ptmux;\033" + sequence + "\033\\"
    try:
        sys.stdout.write(sequence)
        sys.stdout.flush()
    except (OSError, ValueError):
        pass


# --- the curses layer, which draws the above and nothing more


SESSIONS, ENTRIES, DETAIL, HANDOVER = range(4)

HELP = [
    ("↑ ↓ / j k", "move"),
    ("enter", "open"),
    ("esc / h", "back"),
    ("a-h", "answer with that option"),
    ("g", "agree with the recommendation"),
    ("i", "type an answer"),
    ("e", "answer in $EDITOR"),
    ("o", "reply, but leave the question open"),
    ("x", "take the answer back"),
    ("y", "compose the batch and copy it"),
    ("d", "show what is hidden"),
    ("?", "this list"),
    ("q", "quit"),
]


class App:
    def __init__(self, root, jump=None):
        self.root = root
        self.known = agents()
        self.rows = sessions(root, self.known)
        self.reveal = False
        self.screen_kind = SESSIONS
        self.cursor = 0
        self.offset = 0
        self.session = None
        self.entries = []
        self.mtime = 0
        # Answers are kept per session rather than per visit, so walking back to
        # the picker to look at another session does not throw away what you
        # have already decided here.
        self.answers = {}
        self.handed = {}
        self.note = ""
        self.handover = ""
        self.quitting = False
        self.helping = False
        if jump:
            for index, row in enumerate(self.visible_rows()):
                if row["session"].startswith(jump) or row["path"] == jump:
                    self.cursor = index
                    self.enter_session(row)
                    break

    # --- what is on screen

    def visible_rows(self):
        """What `just question` would show: live sessions with something open.

        `/tmp` is swept at 30 days, so the glob finds a month of finished
        sessions — 41 of them on the machine this was written on, against five
        that were running. Showing them all is the same as showing nothing.

        Unknown is treated as dead here, but only when the agent listing came
        back at all. With no `claude` on the path every session is unknown, and
        hiding them all would leave an empty picker with nothing to explain it,
        so in that case the rule turns itself off.
        """
        if self.reveal:
            return self.rows
        return [row for row in self.rows
                if row["open"] and (row["live"] or (row["live"] is None and not self.known))]

    def visible_entries(self):
        if self.reveal:
            return self.entries
        return [entry for entry in self.entries if entry["open"]]

    def listing(self):
        return self.visible_rows() if self.screen_kind == SESSIONS else self.visible_entries()

    def current(self):
        items = self.listing()
        return items[self.cursor] if 0 <= self.cursor < len(items) else None

    @property
    def pending(self):
        """This session's answers, waiting to be handed over."""
        if not self.session:
            return {}
        return self.answers.setdefault(self.session["session"], {})

    @property
    def sent(self):
        """The labels of this session's answers you have already taken away."""
        if not self.session:
            return set()
        return self.handed.setdefault(self.session["session"], set())

    # --- reading the file

    def enter_session(self, row):
        self.session = row
        self.mtime = 0
        self.load()
        self.screen_kind = ENTRIES
        self.cursor = 0
        self.offset = 0

    def load(self):
        """Re-read the file when it has changed under us.

        Claude appends rounds and closes entries while this is open, so the
        list is never assumed to be what it was. An answer of yours that comes
        back closed is one Claude has recorded, which is the only honest
        confirmation this program has: it did not write the file, so the file
        saying so is the evidence.
        """
        try:
            stamp = os.path.getmtime(self.session["path"])
        except OSError:
            return
        if stamp == self.mtime:
            return
        self.mtime = stamp
        try:
            self.entries = [e for e in questions.parse(self.session["path"]) if e["labels"]]
        except OSError:
            self.entries = []
        closed = {label for entry in self.entries if not entry["open"] for label in entry["labels"]}
        for label in list(self.pending):
            if label in closed:
                del self.pending[label]
        self.sent.difference_update(closed)
        self.cursor = min(self.cursor, max(len(self.listing()) - 1, 0))

    def state_of(self, entry):
        labels = entry["labels"]
        if not entry["open"]:
            return "answered", curses.A_DIM
        if any(label in self.pending for label in labels):
            if any(label in self.sent for label in labels):
                return "sent", self.paint(3)
            return "ready", self.paint(2)
        return "open", curses.A_NORMAL

    # --- drawing

    def paint(self, pair):
        return curses.color_pair(pair) if curses.has_colors() else curses.A_NORMAL

    def run(self, screen):
        curses.curs_set(0)
        if curses.has_colors():
            curses.use_default_colors()
            for index, colour in ((1, curses.COLOR_RED), (2, curses.COLOR_YELLOW),
                                  (3, curses.COLOR_GREEN)):
                curses.init_pair(index, colour, -1)
        screen.keypad(True)
        while True:
            if self.session and self.screen_kind in (ENTRIES, DETAIL):
                self.load()
            self.draw(screen)
            try:
                key = screen.getch()
            except KeyboardInterrupt:
                return 0
            if self.key(screen, key) is False:
                return 0

    def put(self, screen, y, x, text, attr=curses.A_NORMAL):
        """Write inside the window or not at all.

        A terminal narrower than the text is a normal thing to happen and not a
        traceback.
        """
        height, width = screen.getmaxyx()
        if y < 0 or y >= height or x >= width:
            return
        try:
            screen.addnstr(y, x, text, max(width - x - 1, 0), attr)
        except curses.error:
            pass

    def draw(self, screen):
        screen.erase()
        height, width = screen.getmaxyx()
        if height < 6 or width < 30:
            self.put(screen, 0, 0, "terminal too small")
            screen.refresh()
            return
        if self.helping:
            self.draw_help(screen)
        elif self.screen_kind == HANDOVER:
            self.draw_handover(screen)
        elif self.screen_kind == DETAIL:
            self.draw_detail(screen)
        else:
            self.draw_list(screen)
        screen.refresh()

    def header(self, screen, text, hint):
        height, width = screen.getmaxyx()
        self.put(screen, 0, 0, text, curses.A_BOLD)
        if len(text) + len(hint) + 2 < width:
            self.put(screen, 0, width - len(hint) - 1, hint, curses.A_DIM)
        self.put(screen, 1, 0, "─" * (width - 1), curses.A_DIM)

    def footer(self, screen, keys):
        height, width = screen.getmaxyx()
        self.put(screen, height - 2, 0, "─" * (width - 1), curses.A_DIM)
        note = self.note or keys
        self.put(screen, height - 1, 0, note,
                 self.paint(2) if self.note else curses.A_DIM)

    def draw_list(self, screen):
        height, width = screen.getmaxyx()
        items = self.listing()
        room = height - 4
        if self.cursor < self.offset:
            self.offset = self.cursor
        if self.cursor >= self.offset + room:
            self.offset = self.cursor - room + 1

        if self.screen_kind == SESSIONS:
            hidden = len(self.rows) - len(items)
            self.header(screen, "open questions — %d session%s"
                        % (len(items), "" if len(items) == 1 else "s"),
                        "%d hidden" % hidden if hidden else "")
        else:
            hidden = len(self.entries) - len(items)
            waiting = len(self.pending)
            self.header(screen, "%s — %s%s"
                        % (self.session["hash"], self.session["repo"],
                           "   %d answered, not handed over" % waiting if waiting else ""),
                        "%d hidden" % hidden if hidden else "")

        for index, item in enumerate(items[self.offset:self.offset + room]):
            y = 2 + index
            chosen = self.offset + index == self.cursor
            mark = "▸ " if chosen else "  "
            attr = curses.A_REVERSE if chosen else curses.A_NORMAL
            if self.screen_kind == SESSIONS:
                state = "live" if item["live"] else ("dead" if item["live"] is False else "?")
                text = "%s%-6.6s %3d open  %s  %-18.18s %-16.16s %s" % (
                    mark, item["hash"], item["open"],
                    time.strftime("%H:%M", time.localtime(item["mtime"])),
                    item["repo"], item["name"], state)
            else:
                state, state_attr = self.state_of(item)
                text = "%s%-11s %-8s %s" % (mark, ", ".join(item["labels"]),
                                            state, item["heading"])
                if not chosen:
                    attr = state_attr
            self.put(screen, y, 0, text, attr)

        if not items:
            self.put(screen, 3, 2, "nothing here — press d to show what is hidden",
                     curses.A_DIM)
        if self.screen_kind == SESSIONS:
            self.footer(screen, "enter open   d hidden   ? keys   q quit")
        else:
            self.footer(screen, "enter read   g agree   a-h option   i type   "
                                "o leave open   y copy   ? keys")

    def draw_detail(self, screen):
        height, width = screen.getmaxyx()
        entry = self.current()
        if entry is None:
            self.screen_kind = ENTRIES
            return
        state, _ = self.state_of(entry)
        self.header(screen, "%s — %s" % (", ".join(entry["labels"]), entry["heading"]),
                    state)
        lines = []
        for raw in entry["lines"]:
            stripped = raw.rstrip("\n")
            if not stripped.strip():
                lines.append("")
                continue
            lines += textwrap.wrap(stripped, max(width - 4, 20),
                                   subsequent_indent="    ") or [""]
        room = height - 4
        self.offset = max(0, min(self.offset, max(len(lines) - room, 0)))
        for index, line in enumerate(lines[self.offset:self.offset + room]):
            self.put(screen, 2 + index, 2, line)
        answer = self.pending.get(entry["labels"][0])
        if answer and not self.note:
            self.note = "answered: %s" % summary(answer)
        self.footer(screen, "↑↓ scroll   g agree   a-h option   i type   "
                            "o leave open   x undo   esc back")

    def draw_handover(self, screen):
        height, width = screen.getmaxyx()
        self.header(screen, "paste this into %s's terminal" % self.session["hash"],
                    "%d answer%s" % (len(self.pending),
                                     "" if len(self.pending) == 1 else "s"))
        lines = self.handover.splitlines()
        for index, line in enumerate(lines[:height - 5]):
            self.put(screen, 2 + index, 2, line)
        y = min(len(lines), height - 5) + 3
        self.put(screen, y, 2,
                 "copied with OSC 52. If your terminal ignores it, select the text above.",
                 curses.A_DIM)
        self.footer(screen, "y copy again   esc back")

    def draw_help(self, screen):
        self.header(screen, "keys", "")
        for index, (key, what) in enumerate(HELP):
            self.put(screen, 2 + index, 2, "%-12s %s" % (key, what))
        self.footer(screen, "any key to go back")

    # --- keys

    def key(self, screen, key):
        self.note = ""
        if self.helping:
            self.helping = False
            return None
        if key in (ord("?"),):
            self.helping = True
            return None
        if key == ord("q"):
            return self.quit()
        self.quitting = False

        if self.screen_kind == HANDOVER:
            if key == ord("y"):
                to_clipboard(self.handover)
                self.note = "copied again"
            elif key in (27, ord("h"), curses.KEY_LEFT, ord("\n"), curses.KEY_ENTER, 10, 13):
                self.sent.update(self.pending)
                self.screen_kind = ENTRIES
            return None

        if key in (curses.KEY_DOWN, ord("j")):
            self.move(1)
        elif key in (curses.KEY_UP, ord("k")):
            self.move(-1)
        elif key in (curses.KEY_NPAGE,):
            self.move(10)
        elif key in (curses.KEY_PPAGE,):
            self.move(-10)
        elif key == ord("d"):
            self.reveal = not self.reveal
            self.cursor = 0
            self.offset = 0
            self.note = "showing everything" if self.reveal else "hiding what is settled"
        elif key in (ord("\n"), curses.KEY_ENTER, 10, 13, curses.KEY_RIGHT, ord("l")):
            self.forward()
        elif key in (27, ord("h"), curses.KEY_LEFT):
            self.back()
        elif self.screen_kind in (ENTRIES, DETAIL):
            self.answer_key(screen, key)
        return None

    def move(self, delta):
        if self.screen_kind == DETAIL:
            self.offset = max(0, self.offset + delta)
            return
        items = self.listing()
        if items:
            self.cursor = max(0, min(self.cursor + delta, len(items) - 1))

    def forward(self):
        item = self.current()
        if item is None:
            return
        if self.screen_kind == SESSIONS:
            self.enter_session(item)
        elif self.screen_kind == ENTRIES:
            self.screen_kind = DETAIL
            self.offset = 0

    def back(self):
        if self.screen_kind == DETAIL:
            self.screen_kind = ENTRIES
            self.offset = 0
        elif self.screen_kind == ENTRIES:
            # No warning here: the answers are kept under this session's id and
            # are still there when you come back. Only quitting loses them, and
            # quitting is what asks.
            self.screen_kind = SESSIONS
            self.session = None
            self.cursor = 0
            self.offset = 0

    def answer_key(self, screen, key):
        entry = self.current()
        if entry is None:
            return
        label = entry["labels"][0]
        if key == ord("g"):
            if not entry["recommendation"]:
                self.note = "%s recommends nothing to agree with — type an answer" % label
                return
            self.record(entry, AGREE, "")
        elif key == ord("x"):
            for name in entry["labels"]:
                self.pending.pop(name, None)
                self.sent.discard(name)
            self.note = "%s taken back" % label
        elif key == ord("i"):
            text = self.ask(screen, "%s: " % label)
            if text:
                self.record(entry, PROSE, text)
        elif key == ord("o"):
            text = self.ask(screen, "%s, still open: " % label)
            if text:
                self.record(entry, OPEN, text)
        elif key == ord("e"):
            text = self.edit(screen, entry)
            if text:
                self.record(entry, PROSE, text)
        elif key == ord("y"):
            self.compose_batch()
        elif ord("a") <= key <= ord("h"):
            letter = chr(key)
            if letter not in entry["options"]:
                self.note = "%s offers no option (%s)" % (label, letter)
                return
            self.record(entry, OPTION, "(%s)" % letter)

    def record(self, entry, kind, text):
        # A paired label is answered once and named once. `Q7 / Q11` is one
        # decision, and writing it twice would read as two.
        for name in entry["labels"]:
            self.pending.pop(name, None)
            self.sent.discard(name)
        self.pending[entry["labels"][0]] = {
            "label": " / ".join(entry["labels"]),
            "kind": kind,
            "text": text,
        }
        self.note = "%s: %s" % (entry["labels"][0], summary(self.pending[entry["labels"][0]]))

    def compose_batch(self):
        if not self.pending:
            self.note = "nothing answered yet"
            return
        answers = [dict(answer, label=answer["label"].split(" / ")[0])
                   for answer in self.pending.values()]
        self.handover = compose(self.session["hash"], self.session["repo"], answers)
        to_clipboard(self.handover)
        self.screen_kind = HANDOVER
        self.offset = 0

    def quit(self):
        """Quitting is the only thing that loses an answer, so it is the only
        thing that asks. It counts across every session, because the one you are
        not looking at is the one you will forget."""
        waiting = sum(len(set(answers) - self.handed.get(session, set()))
                      for session, answers in self.answers.items())
        if waiting and not self.quitting:
            self.quitting = True
            self.note = "%d answer%s never handed over — press q again to lose them" % (
                waiting, "" if waiting == 1 else "s")
            return None
        return False

    # --- the two ways of typing an answer

    def ask(self, screen, prompt):
        """A one-line prompt at the foot of the screen.

        Enough of a line editor for a letter or a sentence, and no more: `e`
        opens `$EDITOR` for anything that wants paragraphs, because an editor
        written inside a curses app is never as good as the one you already
        have.
        """
        height, width = screen.getmaxyx()
        buffer = ""
        curses.curs_set(1)
        try:
            while True:
                self.put(screen, height - 1, 0, " " * (width - 1))
                self.put(screen, height - 1, 0, (prompt + buffer)[-(width - 2):])
                screen.refresh()
                key = screen.getch()
                if key in (27,):
                    return ""
                if key in (ord("\n"), curses.KEY_ENTER, 10, 13):
                    return buffer.strip()
                if key in (curses.KEY_BACKSPACE, 127, 8):
                    buffer = buffer[:-1]
                elif 32 <= key < 127:
                    buffer += chr(key)
        finally:
            curses.curs_set(0)

    def edit(self, screen, entry):
        """`$EDITOR` on a scratch file, seeded with the question as comments.

        The question is in the file so you can answer it without holding it in
        your head, and the lines are dropped on the way back out.
        """
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
        seed = ["# %s" % line.rstrip("\n") for line in entry["lines"]]
        seed += ["# lines beginning with # are dropped", ""]
        handle, path = tempfile.mkstemp(suffix=".md", prefix="answer-")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as out:
                out.write("\n".join(seed))
            curses.endwin()
            subprocess.call([editor, path])
            screen.clear()
            curses.doupdate()
            with open(path, encoding="utf-8") as back:
                body = [line.rstrip("\n") for line in back if not line.startswith("#")]
            return "\n".join(body).strip()
        except OSError as problem:
            self.note = "could not run %s: %s" % (editor, problem)
            return ""
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass


def summary(answer):
    if answer["kind"] == AGREE:
        return "agreed"
    if answer["kind"] == OPEN:
        return "left open"
    return answer["text"].splitlines()[0][:40] if answer["text"] else "answered"


if __name__ == "__main__":
    sys.exit(main(sys.argv))
