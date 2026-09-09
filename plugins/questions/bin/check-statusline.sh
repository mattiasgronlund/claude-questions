#!/usr/bin/env bash
# Runs the status line against its cases. It is checked because it is the one
# piece of this that nothing else would notice going wrong: it renders below the
# prompt, it never fails a build, and a miscount reads exactly like a correct
# count of a different number.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
line="$here/statusline.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
file="$work/open-questions.md"

failed=0
total=0

render() {
	jq -n --arg d "$work" --argjson t "$1" \
		'{model: {display_name: "Opus"}, context_window: {total_input_tokens: $t}, workspace: {project_dir: $d}}' |
		CLAUDE_CONTEXT_BUDGET=300000 CLAUDE_QUESTIONS_FILE="$2" "$line" | sed -e 's/\x1b\[[0-9;]*m//g'
}

want() {
	total=$((total + 1))
	local got
	got=$(render "$2" "$3")
	if ! grep -qE "$4" <<<"$got"; then
		printf 'wanted /%s/, got: %s\n  (%s)\n' "$4" "$(tr '\n' '|' <<<"$got")" "$1"
		failed=$((failed + 1))
	fi
}

reject() {
	total=$((total + 1))
	local got
	got=$(render "$2" "$3")
	if grep -qE "$4" <<<"$got"; then
		printf 'did not want /%s/, got: %s\n  (%s)\n' "$4" "$(tr '\n' '|' <<<"$got")" "$1"
		failed=$((failed + 1))
	fi
}

# The shipped default, with nothing in the environment. This is the case that
# notices the two defaults — the hook's and the status line's — drifting apart.
# They are defaults in two plugins now, which can be installed one without the
# other, so neither can read the other's number and this is what holds them.
total=$((total + 1))
shipped=$(jq -n --arg d "$work" '{model: {display_name: "Opus"}, context_window: {total_input_tokens: 125000}, workspace: {project_dir: $d}}' |
	env -u CLAUDE_CONTEXT_BUDGET CLAUDE_QUESTIONS_FILE=/nowhere "$line" | sed -e 's/\x1b\[[0-9;]*m//g')
if ! grep -qE '125k/250k .* 50%' <<<"$shipped"; then
	printf 'wanted the shipped default to read 125k/250k at 50%%, got: %s\n' "$shipped"
	failed=$((failed + 1))
fi

# --- line 1, which is the half the user reads most
want "the budget line renders" 150000 /nowhere '150k/300k .* 50%'
reject "under budget does not say hand off" 150000 /nowhere 'hand off'
want "over budget says hand off" 340000 /nowhere 'hand off'
want "over budget passes 100%" 340000 /nowhere '11[0-9]%'
reject "a session with no questions file gets one line only" 1000 /nowhere '(open|❓|✓)'

# --- line 2
printf '# Open questions\n\n' >"$file"
want "a file with no questions says so" 1000 "$file" 'no open questions'

cat >"$file" <<'FILE'
# Open questions

- [ ] **Q2** — Run the sweep now? → *recommend now*
- [ ] **Q4** — Bump the pin? → *recommend after*
- [ ] **Q5** — Keep the branch? → *recommend yes*
- [ ] **Q6** — Push tonight? → *recommend yes*
- [x] **Q1** — Was this asked? → answered: yes
- [x] **Q3** — And this? → answered: yes
FILE
want "a lone number and a run collapse together" 1000 "$file" '❓ Q2, Q4-Q6$'
reject "an answered question is not open" 1000 "$file" 'Q1|Q3'
reject "the recommendation stays in the file" 1000 "$file" 'recommend'

cat >"$file" <<'FILE'
- [ ] **Q3** — One? → *a*
- [ ] **Q4** — Two? → *b*
FILE
want "a run of exactly two is spelled out, not hyphenated" 1000 "$file" '❓ Q3, Q4$'

cat >"$file" <<'FILE'
- [ ] **Q2** — a?
- [ ] **Q3** — b?
- [ ] **Q4** — c?
- [ ] **Q5** — d?
- [ ] **Q6** — e?
- [ ] **Q7** — f?
- [ ] **Q8** — g?
FILE
want "a long run is one range" 1000 "$file" '❓ Q2-Q8$'

cat >"$file" <<'FILE'
- [ ] **Q10** — later?
- [ ] **Q9** — earlier?
- [ ] **Q9** — a duplicate line?
FILE
want "out of order sorts numerically and dedupes" 1000 "$file" '❓ Q9, Q10$'

# A wave numbers a lane's findings by the lane's letter, so "Lane K" produces
# K1-K4. Dropping them because they were not Q was a real miss.
cat >"$file" <<'FILE'
- [ ] **K1** — the hole?
- [ ] **K2** — the false claim?
- [ ] **K3** — refuse or skip?
- [ ] **K4** — both corrected?
- [ ] **Q2** — a grilling question?
FILE
want "a lane's letter series survives" 1000 "$file" 'K1-K4'
want "two series are both shown" 1000 "$file" '❓ K1-K4, Q2$'

cat >"$file" <<'FILE'
- [ ] **Q3** — does the body mention M5 or Q9 in passing?
FILE
want "the label is the one after the checkbox, not the first in the body" 1000 "$file" '❓ Q3$'
reject "a number mentioned in the body is not a question" 1000 "$file" 'M5|Q9'

cat >"$file" <<'FILE'
Example of the format:

```
- [ ] **Q99** — this is documentation, not a question
```

- [ ] **Q1** — a real one?
FILE
want "a fenced example is not a question" 1000 "$file" '❓ Q1$'
reject "the fenced number does not leak" 1000 "$file" 'Q99'

# An entry the reader cannot name is still an entry. Dropping it is how a
# question goes missing while the line looks complete, which is the one failure
# this line cannot have.
cat >"$file" <<'FILE'
- [ ] **Q1** — a real one?
- [ ] **handoff Q2** — a label the reader cannot parse
FILE
want "an unparsable label is counted, not dropped" 1000 "$file" '❓ Q1, \?\?×1$'

cat >"$file" <<'FILE'
# Open questions

- [ ] **Q1** — before the heading?

## A section, which belongs to the document

- [ ] **Q2** — after it?
FILE
want "document headings do not disturb the count" 1000 "$file" '❓ Q1, Q2$'
reject "a heading is not a question" 1000 "$file" 'section'

if [ "$failed" -gt 0 ]; then
	echo "$failed of $total status line cases came out wrong"
	exit 1
fi

echo "$total status line cases, all as expected"

# The TUI is the parser's third caller and the one a person types into.
# It is checked here for the same reason the status line is: it is downstream of
# the same grammar, and a copy of that grammar is what this repo exists to end.
exec "$here/check-tui.sh"
