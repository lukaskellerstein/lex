---
description: "Step 3: Implement — coding rules and this project's layout"
---

# Step 3: Implement

Write clean code from the start. Follow these rules during implementation:

- Every edit stays in the checkout assigned to this session. Claude Code uses
  `.worktrees/<name>`; Codex uses its active Local or managed Worktree checkout
  and Handoff. Never edit another checkout — [`worktree.md`](worktree.md)
- Do NOT commit via `git` unless explicitly instructed by the user
- When creating diagrams or graphs, use `mermaid`
- Write clean code from the start — don't plan to "clean it up later"
- Refactor continuously — improve code structure immediately when you see issues
- Remove dead code — delete unused functions, variables, imports, and commented code
- Before changing any signature, renaming, or deleting something shared, find
  every caller with `findReferences` where the `LSP` tool is available — grep
  misses the ones spelled differently and finds ones that are not calls.
  [`lsp.md`](lsp.md)
- After writing code: review comments, clean up imports, check for side effects

## `lua/lex/` — the reader

One module per concern, each opening with a comment that says what it is for
(`lex.anchor: find the lines a record talks about in the file as it is now`).
Keep that shape: a new concern is a new module with its own header line, not a
section appended to `init.lua`.

- `place.lua` is the **reference parser** of the `<lex-place>` block. The
  writers must agree with it; `tests/place_test.lua` holds it to `contract/`.
- `store.lua` owns where records live and how they are read. The link file is
  **append-only** — forgetting appends a marker and never rewrites the file,
  because an agent's writer can be appending at the same moment.
- `locate.lua` and `open.lua` call `ps`, `lsof`, `tmux` and terminal launchers.
  Each is optional: a missing tool means fewer jump targets, never an error.

## `plugin/lex.lua` — the commands

User commands only, sourced once behind `vim.g.loaded_lex`. Logic lives in
`lua/lex/`; a command body handles its arguments and calls into a module.

## `agents/` — the writers

- `agents/claude-code/hook.lua` serves Claude Code **and** Codex under `nvim -l`.
  `agents/opencode/index.ts` serves OpenCode, with no imports beyond node's own.
- A writer **never fails the prompt, never prints to stdout, and runs no git or
  network**. Failures go to `$LEX_HOME/hook.log`. Breaking any of the three
  breaks every live agent session on this machine.
- The two writers are two languages with one behaviour. Change them together.

## `contract/` — what keeps the writers equal

`prompt.txt` and `records.json` are the normative example. Change the block
syntax or the record shape here first, then make every writer and `place.lua`
pass against it.

## `tests/`

One `*_test.lua` per area, runnable alone with `nvim -l`, each working in its
own temp directory. No test may touch the real `~/.lex` or a real
agent config — set `LEX_HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and
`XDG_CONFIG_HOME` the way `tests/install_test.lua` does.

## `prototype/` and `docs/`

`prototype/marks.lua` is the visual prototype `PLAN.md` refers to; it is not
loaded by the plugin. `docs/architecture.md` must change with the store format
or the session lookup it describes.

## Repository structure

```text
lex/
├── plugin/lex.lua            user commands
├── lua/lex/                  the reader: anchor, conv, copy, explorer, health,
│                             init, install, json, links, locate, marks, open,
│                             pending, picker, place, statusline, store
├── agents/
│   ├── claude-code/          hook.lua (Claude Code + Codex), hooks/hooks.json,
│   │                         .claude-plugin/plugin.json
│   └── opencode/             index.ts, package.json
├── contract/                 prompt.txt, records.json, README.md
├── tests/                    *_test.lua, opencode_test.ts, run.sh
├── prototype/marks.lua
├── docs/                     architecture.md, demo.svg, logo/
├── .github/workflows/tests.yml
├── PLAN.md                   the design journal
└── README.md
```
