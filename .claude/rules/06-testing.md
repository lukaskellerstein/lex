---
description: "Step 4: Testing — define DoD, test, fix and repeat until passing"
---

# Step 4: Testing

**Every code change must be tested before reporting completion. No exceptions.**

## 4a. Define your Definition of Done

Before testing, **write out your DoD checklist in the conversation** so the user
can see what you intend to verify. Example:

> **Definition of Done for this task:**
>
> - [ ] A range whose lines moved down three rows still resolves as `moved`
> - [ ] `tests/anchor_test.lua` has a case for it, and it failed before the fix
> - [ ] `sh tests/run.sh` passes in full

## 4b. Test

**Every change to `lua/`, `plugin/`, `agents/` or `contract/`** — add or change
the case in the matching `tests/*_test.lua` (or `tests/opencode_test.ts`) so it
fails without your change, then run the whole suite from your worktree:

```bash
sh tests/run.sh
```

It runs from the worktree's own root, so it tests your code and not the live
checkout. If it prints `tests/opencode_test.ts: skipped, bun not on PATH`, say
so in the report — a writer change is not verified without that test.

A behaviour the suite cannot reach (a real tmux pane, a terminal launcher, the
look of the marks) needs a headless `nvim -l` script of your own, with
`LEX_HOME` and the agent config variables pointed into a temp directory. Never
verify against the real `~/.lex` or a real agent config.

**Every code change** — repo-wide lint / format / type check:

```bash
nvim-tools --json --all
```

Your change must not add findings, measured against the baseline you took in the
Understand step. How to read the output (including `gated-off`), and why this
never replaces the project's own suite: [`machine-tools.md`](machine-tools.md).

**Non-testable changes** (docs, config, IaC only): explicitly state why no
runtime test is needed.

## 4c. Fix and repeat

If a test fails: fix the issue, then retest. Repeat until all DoD items pass. If
you hit a problem you repeatedly cannot resolve, ask the user for help rather
than reporting partial success.

## 4d. Never report completion without testing

If you write code and stop without verifying it works, you have failed. Testing
is YOUR responsibility — the user should never need to ask you to test.
