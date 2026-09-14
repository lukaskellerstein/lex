---
description: Project configuration — architecture, paths, dev environment
---

# Project Config

- **Project**: lex — a Neovim plugin that links a place in a code file to the AI
  agent conversations (Claude Code, Codex, OpenCode) that talked about it, and
  takes you back into one.
- **Architecture**: two halves. The **writer** (`agents/`) is a hook inside each
  agent: on every prompt it finds the `<lex-place>` blocks and appends one JSON
  record per place to `$LEX_HOME/<readable-repo>--<hash>/links.jsonl`. The
  **reader** (`lua/lex/`, `plugin/lex.lua`) indexes that store, re-anchors each
  range against today's file by its text, paints marks, and reopens the
  conversation. `contract/` keeps the writers equal.
  [`docs/architecture.md`](../../docs/architecture.md) has the data flow.
- **Structure**: `lua/lex/` reader modules · `plugin/lex.lua` user commands ·
  `agents/claude-code/` the Lua writer for Claude Code and Codex, run by
  `nvim -l`, plus its plugin manifest · `agents/opencode/` the TypeScript writer ·
  `contract/` cross-writer fixtures · `tests/` · `prototype/` the visual
  prototype · `docs/` · `PLAN.md` the design journal
- **Build**: none — Lua loads from the runtimepath, and OpenCode runs
  `agents/opencode/index.ts` as source.
- **Run locally**: no server. Inside Neovim, `:checkhealth lex` reads each
  agent's config and runs the writer once into a throwaway store.
- **Test**: `sh tests/run.sh` — every `tests/*_test.lua` under `nvim -l`, then
  `tests/opencode_test.ts` under `bun` (skipped when `bun` is not on `PATH`).
  CI: `.github/workflows/tests.yml`, Neovim v0.11.4 and stable, Bun 1.3.14.
- **Key dependencies**: Neovim 0.11+ (LuaJIT), snacks.nvim (the picker).
  Optional: tmux (pane jumps and resume targets), `ps` and `lsof` (live-session
  discovery), Bun (the OpenCode test).
- **Package manager**: none. Users install the plugin with lazy.nvim;
  `agents/opencode/package.json` declares no dependencies.

## Paths outside this repo

All read-only unless the user says otherwise — `CLAUDE.md` § Requires
confirmation.

| Path | What it is |
|:--|:--|
| `~/.lex` (`$LEX_HOME`) | the real store: `<repo>--<hash>/links.jsonl`, `sessions/`, `hook.log` |
| `~/.claude/settings.json` | the live Claude Code writer — hook entries pointing at this checkout's `agents/claude-code/hook.lua` |
| `~/.codex/config.toml` | the Codex writer entry |
| `~/.config/opencode/plugin/lex.ts` | the installed OpenCode writer |
| `~/Projects/Github/lukaskellerstein/mac-setup/modules/nvim/config/nvim/lua/plugins/lex.lua` | loads this checkout into LazyVim (`dir =`) |
| `~/Projects/Github/lukaskellerstein/mac-setup/modules/nvim/config/nvim/lua/config/ai-ref.lua` | the right-click menu that calls `lex.place` |
| `~/Projects/Github/lukaskellerstein/rex` | the sibling app that does the same for documents; `PLAN.md` refers to it |
