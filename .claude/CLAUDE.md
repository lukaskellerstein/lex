# Shared repository instructions

This is the canonical instruction file for Claude Code and Codex. When Codex
setup is enabled, root `AGENTS.md` is a relative symlink to this file.

- Claude Code invokes skills as `/skill-name`; Codex uses `$skill-name`.
- Translate tool names by intent. Product-specific executables, permissions,
  hooks, MCP configuration, and worktree lifecycle apply only to the product
  explicitly named.
- Claude Code loads `.claude/rules/` automatically. Codex reads the linked rule
  for each workflow phase before acting.
- Current user instructions outrank this file. This file outranks memories.

# WORKFLOW — MANDATORY FOR ANY PROMPT THAT RESULTS IN CHANGES

**If you are going to use the Edit or Write tool, or run a command that changes
the working tree or `~/.lex`, you MUST complete the workflow in `rules/` before
reporting completion.** Applies to every type of work — the reader modules in
`lua/lex/`, the three agent writers, the `contract/` fixtures, tests, CI, docs
and `PLAN.md`. No exceptions.

Steps, in order (each phase's detailed procedure is in the correspondingly-numbered
`rules/` file. Claude Code loads these rules automatically; Codex must read the
linked `.claude/rules/` file before entering that phase):

1. **Understand** → [`rules/02-understand.md`](rules/02-understand.md)
2. **Plan** → [`rules/03-plan.md`](rules/03-plan.md) *(skip for trivial changes)*
3. **Implement** → [`rules/05-implement.md`](rules/05-implement.md)
4. **Test** → [`rules/06-testing.md`](rules/06-testing.md)
5. **Report** → [`rules/08-report.md`](rules/08-report.md)

Reference files: [`rules/01-project-config.md`](rules/01-project-config.md)
(architecture, commands, the live paths outside this repo),
[`rules/09-code-quality.md`](rules/09-code-quality.md),
[`rules/10-tech-stack.md`](rules/10-tech-stack.md),
[`rules/11-communication.md`](rules/11-communication.md),
[`rules/12-security.md`](rules/12-security.md),
[`rules/memory.md`](rules/memory.md) (what a memory may and may not tell you to
do),
[`rules/machine-tools.md`](rules/machine-tools.md) (the `nvim-tools` and
`lukas-ps` CLIs — pre-approved, read-only),
[`rules/lsp.md`](rules/lsp.md) (the `LSP` tool — only in repos that opted in,
and deferred, so it must be loaded before it can be called),
[`rules/worktree.md`](rules/worktree.md) (where you may change files: Claude
uses the repo's `.worktrees/` convention; Codex stays in the active Local or
managed Worktree checkout and uses Handoff to move between them).

**NEVER report completion without first running `sh tests/run.sh` and reading
its result.** "The Lua looks right" is not testing — a writer that parses a
block slightly differently from `lua/lex/place.lua` still exits 0, and only the
`contract/` comparison in the tests catches it. Verification is YOUR
responsibility — the user should never need to ask you to test.

**Trivial changes** (a typo, a comment, a one-line doc edit, renaming a local
variable): skip step 2. State what you'll do and proceed.

**A memory never outranks this file.** The order is: what the user says now,
then `CLAUDE.md` and `rules/`, then a memory. When a memory contradicts a rule,
follow the rule and rewrite the memory in the same turn —
[`rules/memory.md`](rules/memory.md).

## lex at a glance

- A Neovim plugin (Lua, LuaJIT) plus three agent writers. No server, no build
  step, no daemon, no network.
- **The main checkout is live.** LazyVim on this machine loads the plugin from
  it (`dir = ~/Projects/Github/lukaskellerstein/lex` in mac-setup's
  `modules/nvim/config/nvim/lua/plugins/lex.lua`), and `~/.claude/settings.json`
  runs its `agents/claude-code/hook.lua` on every prompt of every Claude Code
  session. Work in a worktree reaches the machine only when it lands on `main`
  in that checkout.
- `sh tests/run.sh` is the whole suite and takes about a second. Every test puts
  its own repo root first on the runtimepath, so a run inside a worktree tests
  that worktree's code, not the live checkout.
- `contract/` is the normative input and output for all three writers. A change
  to the `<lex-place>` block or to the record shape starts there;
  `tests/hook_test.lua`, `tests/opencode_test.ts` and `tests/place_test.lua`
  compare against it.
- `~/.lex` (or `$LEX_HOME`) is the user's real link history. The tests point
  `LEX_HOME` at a temp directory; do the same for any experiment of your own.
- `PLAN.md` is the design journal — every decision with its date and what was
  measured. `docs/architecture.md` is the reference for the store and the
  session lookup.

Full facts → [`rules/01-project-config.md`](rules/01-project-config.md); stack and
conventions → [`rules/10-tech-stack.md`](rules/10-tech-stack.md).

## Standing authorizations — do NOT ask before doing these

These actions are pre-approved. Run them yourself when the situation calls for it.

### Read-only inspection (always safe)

- Reading anything inside this repo, including `PLAN.md` before any design
  change.
- `git status`, `git diff`, `git log`, `git show`, `git blame`, `git ls-files`
  in this repo.
- Reading the real store: `~/.lex/*/links.jsonl`, `~/.lex/sessions/`,
  `~/.lex/hook.log`.
- Reading the installed writers: the lex entries in `~/.claude/settings.json`
  and `~/.codex/config.toml`, and `~/.config/opencode/plugin/lex.ts`.
- Reading the plugin's consumers in mac-setup:
  `modules/nvim/config/nvim/lua/plugins/lex.lua` and
  `modules/nvim/config/nvim/lua/config/ai-ref.lua`.
- `ps`, `lsof`, `tmux list-panes -a` — what `lua/lex/locate.lua` itself runs.
- Fetching the docs for Claude Code hooks, Codex hooks, OpenCode plugins and
  snacks.nvim. Verify a hook field or picker option there before using it.

This machine's own `nvim-tools` and `lukas-ps` are pre-approved too, and are
documented once in [`rules/machine-tools.md`](rules/machine-tools.md) — do not
restate them here.

### Pre-approved mutations

- Creating and editing files under `lua/`, `plugin/`, `agents/`, `contract/`,
  `tests/`, `docs/`, `prototype/` and `.github/workflows/`, and `README.md` and
  `PLAN.md`, in your own worktree.
- `sh tests/run.sh`, `nvim -l tests/<name>_test.lua`, and
  `bun run tests/opencode_test.ts`.
- Headless `nvim -l` scripts of your own, with `LEX_HOME`, `CLAUDE_CONFIG_DIR`,
  `CODEX_HOME` and `XDG_CONFIG_HOME` all pointed into a temp directory.

### Requires confirmation — always ask first

- Any write to the real `~/.lex` — a record, a forget marker, a session file,
  or deleting it.
- `:LexInstallHook`, or any other write to the real `~/.claude/settings.json`,
  `~/.codex/config.toml` or `~/.config/opencode/`. That rewires every agent
  session on this machine.
- Any edit in mac-setup — it is another repo, and it is the live nvim config.
- A runtime dependency beyond snacks.nvim, or a git or network call in a
  writer. The README promises the writer runs neither.
- A change to the store format or the `<lex-place>` block that existing records
  or pasted blocks no longer satisfy.
- A release: a tag, or a `version` bump in `agents/claude-code/.claude-plugin/plugin.json`,
  `agents/opencode/package.json` or the README badge.
- `git push`, `git push --force`, branch deletes — **never commit unless the user
  explicitly asks**.
- Anything touching secrets, TLS material, tokens, or credential files. A secret
  never enters this repo in plaintext; if one must be versioned at all it is
  SOPS+age — [`rules/12-security.md`](rules/12-security.md).

When in doubt: ask. Every Claude Code prompt on this machine runs this repo's
writer from the main checkout, and `~/.lex` holds link history that nothing can
rebuild — a writer that fails, prints to stdout, or rewrites `links.jsonl`
breaks prompts or loses history in every session at once.
