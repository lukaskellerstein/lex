# The Claude Code and Codex writer

`hook.lua` handles `UserPromptSubmit`, `Stop`, `SessionStart`, and
`SessionEnd`. It runs under `nvim -l`, reads the hook's JSON on stdin, finds
every `<lex-place>` block in a prompt, and appends one record per block to
`~/.lex/<readable-repo>--<hash>/links.jsonl`. It never
fails the prompt and never prints to stdout. Its header says the rest.

Two ways in:

- **From nvim**: `:LexInstallHook` writes the entry into
  `~/.claude/settings.json` with absolute paths, `:LexInstallHook codex`
  appends the same command to `~/.codex/config.toml`. `:checkhealth lex`
  checks both and runs the hook once.
- **As a Claude Code plugin**: this folder is a plugin (`.claude-plugin/`,
  `hooks/hooks.json`). The plugin form needs `nvim` on Claude Code's PATH,
  which a session started from a terminal has and one started from the
  desktop app may not. Not yet exercised; the nvim command is the tested path.

Codex trusts a hook only after you press `t` in its TUI once. Until then
`/hooks` there shows the hook as installed and not active, and no record is
written. The installer emits Codex's documented nested handler tables and
recognizes the older inline-array form written by Lex 0.1.0.
