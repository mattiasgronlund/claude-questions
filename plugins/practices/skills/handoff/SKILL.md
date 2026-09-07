---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up. Use when the context budget hook says the budget is passed, or when the user asks to hand off.
argument-hint: "What will the next session be used for?"
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save to the temporary directory of the user's OS - not the current workspace.

Include a "suggested skills" section in the document, naming which skills the next agent should call the Skill tool for.

**Include a "still in flight" section, and generate it rather than recall it.** Run the commands and paste what they say:

- Your repo's command for listing worktrees and their locks — in `rcad`, `just lanes` — which says which are held, and the reason naming the agent holding each.
- `ListAgents` — which peer sessions are live.
- Which worktrees are this session's own, and which of them are dirty.

Generate it because the outgoing session's belief about what it left running is not reliable. The 2026-09-05 handoff doc said "No lanes running" on the writing agent's own initiative; nothing had checked, and nothing could have, because `/clear` destroys the only session-side record of a dispatch. The lock survives it and a memory does not.

Say "nothing in flight" only when the commands say so. An empty section reads as "not checked", which is where the next session's wasted hour comes from.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
