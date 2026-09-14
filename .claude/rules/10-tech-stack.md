---
description: "Reference: Technology stack — a Lua (LuaJIT) Neovim plugin, with Lua and TypeScript agent writers"
---

# Reference: Technology Stack

## The plugin

- **Language**: Lua 5.1 / LuaJIT, as embedded in Neovim
- **Host**: Neovim 0.11+ — CI tests v0.11.4 and stable; this machine runs 0.12
- **UI**: snacks.nvim picker (required); extmarks for the marks and badges
- **Optional integrations**: tmux, lualine (`lua/lex/statusline.lua`), the
  snacks explorer (`lua/lex/explorer.lua`)

## The writers

- **Claude Code and Codex**: `agents/claude-code/hook.lua`, run by `nvim -l`
- **OpenCode**: `agents/opencode/index.ts` — TypeScript, node built-ins only
- **Store**: append-only JSON Lines under `$LEX_HOME` (default `~/.lex`)

## Tests and CI

- Headless `nvim -l` for every Lua test; Bun 1.3.x for the OpenCode test
- GitHub Actions: `.github/workflows/tests.yml`

## Scripting & Automation

- Default: Lua under `nvim -l` for scripts, consistent with the rest of the stack
- Shell scripts only for trivial one-liners

## Conventions this machine imposes

- **One formatter per filetype.** Biome owns the JS/TS family; prettier and
  eslint are not installed. Python formats with the ruff CLI chain.
- Tools run only where the repo carries their config file — see
  `rules/09-code-quality.md`.
