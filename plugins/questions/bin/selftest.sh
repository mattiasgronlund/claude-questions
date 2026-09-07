#!/usr/bin/env bash
# Pins the parser against a questions root it builds itself, so it stays proven
# on a machine where no session happens to be live.
#
# Four of these cases are bugs that were live on 2026-09-07, and each is here
# because nothing else would have noticed it:
#
#   - a paired label, `**Q7 / Q11**`, counted as one question and hid Q11;
#   - a fenced example in a body truncated the body at the fence, which the
#     format's own documentation is written as;
#   - a `##` section heading was swallowed into the entry above it;
#   - an entry whose label does not parse vanished from the count and the
#     listing alike, which is the one thing this must never do.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
q="$here/questions.py"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
scratch="$root/-slug-rcad/76640573-f351-4e74/scratchpad"
mkdir -p "$scratch"
file="$scratch/open-questions.md"

failed=0
total=0

fail() {
	printf '  %s\n' "$1"
	failed=$((failed + 1))
}

# Every assertion goes through one of these three, so a case cannot pass by
# forgetting to check anything.
same() {
	total=$((total + 1))
	[ "$2" = "$3" ] && return
	fail "$1"
	printf '    got:  %s\n    want: %s\n' "$(tr '\n' '|' <<<"$2")" "$(tr '\n' '|' <<<"$3")"
}

holds() {
	total=$((total + 1))
	grep -qE "$3" <<<"$2" || fail "$1"
}

lacks() {
	total=$((total + 1))
	grep -qE "$3" <<<"$2" && fail "$1"
}

# --- reading: a file with every shape that has ever broken a reader in it
fence='```'
printf '%s\n' \
	'# Open questions' \
	'' \
	'- [ ] **Q7 / Q11** — a floor unit with no record' \
	'' \
	'  An indented body that belongs to Q7, mentioning M5 and Q99 in passing.' \
	'' \
	"$fence" \
	'- [ ] **Q99** — documentation of the format, not a question' \
	"$fence" \
	'' \
	'  BODY-CONTINUES-PAST-THE-FENCE' \
	'' \
	'## A section heading, which belongs to the document' \
	'' \
	'- [x] **Q24** — settled, and must not be counted as open' \
	'- [ ] **handoff Q1** — a label the reader cannot parse' \
	'- [ ] **K1** — a lane keeps its own letter' \
	>"$file"

clock=$(date -d "@$(stat -c %Y "$file")" +%H:%M)
same "the session list drifted" \
	"$(python3 "$q" sessions "$root")" \
	"  766405   4 open  $clock  rcad"

same "the label listing drifted" \
	"$(python3 "$q" labels "$file" | awk '{ $1 = $1; print }')" \
	"$(printf '%s\n' 'Q7, Q11 open a floor unit with no record' \
		'Q24 done settled, and must not be counted as open' \
		'?? open line 16: **handoff Q1** — a label the reader cannot parse' \
		'K1 open a lane keeps its own letter')"

same "a paired label is not reachable by both of its names" \
	"$(python3 "$q" entry "$file" Q7)" "$(python3 "$q" entry "$file" Q11)"

body=$(python3 "$q" entry "$file" Q11)
holds "the body did not come back with the question" "$body" 'indented body'
holds "a fenced example truncated the body" "$body" 'BODY-CONTINUES-PAST-THE-FENCE'
lacks "a document heading was swallowed into the entry above it" "$body" 'A section heading'
lacks "the entry ran on into the one after it" "$body" 'Q24'

total=$((total + 1))
python3 "$q" entry "$file" Q99 >/dev/null 2>&1 &&
	fail "a label inside a fence was addressable as a question"
total=$((total + 1))
python3 "$q" entry "$file" M5 >/dev/null 2>&1 &&
	fail "a number mentioned in a body was addressable as a question"

same "the open labels collapsed wrongly" \
	"$(python3 "$q" compact "$file")" "K1, Q7, Q11, ??×1"

total=$((total + 1))
python3 "$q" find "$root" zzzz >/dev/null 2>&1 &&
	fail "a hash matching no session was accepted"
same "find did not resolve a hash to its file" \
	"$(python3 "$q" find "$root" 766405)" "$file"

# --- the grammar, one file per rule, because a checker that fires for the
# wrong reason is as bad as one that does not fire.
breaks() {
	total=$((total + 1))
	printf '%s\n' "$2" >"$file"
	local out
	out=$(python3 "$q" check "$file")
	if [ $? -eq 0 ]; then
		fail "the checker passed a file that breaks: $1"
		return
	fi
	grep -qE "$3" <<<"$out" || fail "the checker missed: $1"
}

breaks "options in prose, not marked" \
	'- [ ] **Q1** — pick one? Either (a) do it now or (b) do it later.' \
	'stated in prose but not marked'
breaks "an option set that skips a letter" \
	"$(printf '%s\n' '- [ ] **Q1** — pick one?' '' '  - **(a)** now' '  - **(c)** later' '' '  ➡️ *Recommend (a).*')" \
	'must run from .a. with no gaps'
breaks "options offered with no recommendation" \
	"$(printf '%s\n' '- [ ] **Q1** — pick one?' '' '  - **(a)** now' '  - **(b)** later')" \
	'offers options but recommends none'
breaks "the old recommendation spelling" \
	"$(printf '%s\n' '- [ ] **Q1** — pick one?' '' '  - **(a)** now' '  - **(b)** later' '' '  → *recommend (a)*')" \
	'write .➡️'
breaks "a label that does not parse" \
	'- [ ] **handoff Q1** — no label here' \
	'no label the reader can parse'
breaks "a heading separator that is not an em dash" \
	'- [ ] **Q1** - a hyphen is not the separator' \
	'must be an em dash'

# An answered entry names the letter it chose. Reading that as an offer of
# unmarked options flagged every settled question the first time this ran.
printf '%s\n' \
	'- [x] **Q1** — settled → answered: **(a)**, and nothing here is a violation' \
	>"$file"
total=$((total + 1))
python3 "$q" check "$file" >/dev/null ||
	fail "the checker judged an answered entry for naming its own letter"

printf '%s\n' \
	'- [ ] **Q1** — a well-formed entry, which must raise nothing' \
	'' \
	'  - **(a)** do it now' \
	'  - **(b)** do it later' \
	'' \
	'  ➡️ *Recommend (a), because the body may say anything at all.*' \
	>"$file"
total=$((total + 1))
python3 "$q" check "$file" >/dev/null ||
	fail "the checker fired on an entry that follows the grammar"

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total cases came out wrong"
	exit 1
fi

echo "$total cases, all as expected"
