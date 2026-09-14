# Architecture

Lex has two halves. A writer inside each coding agent turns pasted
`<lex-place>` blocks into records. The Neovim reader indexes those records,
re-anchors their code, paints marks, and opens the originating conversation.

## Data flow

1. `lua/lex/place.lua` copies a file, folder, or line range as a tagged block.
2. The Claude Code/Codex Lua hook or OpenCode TypeScript plugin parses the
   prompt and appends one JSON object per accepted place.
3. `lua/lex/links.lua` reads the store once, tails complete new lines, and
   updates its file and folder indexes.
4. `lua/lex/anchor.lua` resolves a stored range against today's file: exact
   position, exact text elsewhere, fuzzy ordered lines, or orphaned.
5. Marks, explorer integration, the statusline, and the picker consume the
   same in-memory repository index.

The normative cross-language examples and parsing rules live in `contract/`.

## Store

```text
$LEX_HOME/<readable-repo>--<sha256-prefix>/links.jsonl
$LEX_HOME/sessions/<session>.json
$LEX_HOME/hook.log
```

`$LEX_HOME` defaults to `~/.lex`. The readable repository component is capped
at 48 bytes, and a 16-hex-character SHA-256 prefix of the exact main-repository
path makes the directory collision-resistant. Every record also carries the
exact `repo`, and readers reject records for another repository.

Stores created by 0.1.0 used a lossy path-only slug. Lex copies only exact
matching records to the hashed directory and remembers its byte offset in the
legacy file. That incremental import also catches late writes from an adapter
that has not yet been refreshed. The legacy file remains untouched for rollback.

The link file is append-only. A forget operation appends this control record:

```json
{"_lex":"forget","at":1789150926,"session":"…","key":"range:src/auth.ts:12-15"}
```

`key` is omitted when the whole conversation is forgotten. A marker applies
only to matching records before it, so a later prompt with the same session
survives. Most importantly, forgetting never replaces a file while agent hooks
may be appending to it, so a concurrent write cannot be lost.

Session-state files are deliberately mutable. Writers replace the small file
on lifecycle changes (`working`, `idle`, or `ended`), and Neovim watches the
directory to repaint promptly.

## Finding a conversation

Lex never trusts the pane stored at prompt time by itself. It looks for a live
session in this order:

1. a current session-state file whose PID is alive;
2. an agent process whose command line contains the exact session ID;
3. for Codex, a process holding the rollout file open.

The proven process is walked through its parents to a current tmux pane. When
no process is found, Lex offers configured terminal and tmux targets and runs
the agent-specific resume command. Missing `ps`, `tmux`, or `lsof` simply
removes the discovery path that depends on it.

## Concurrency and failures

Writers perform one append per JSON line and never wait for the editor. Readers
ignore malformed and incomplete lines until a complete newline arrives. Hook
errors are appended to `hook.log` and do not reject the user's agent prompt.
OpenCode transcript export is asynchronous in the picker; success and failure
both clear the loading state.

## Tests

`sh tests/run.sh` runs the Lua suite with `nvim -l` and the OpenCode contract
suite with Bun when available. CI runs Neovim 0.11 and the current stable
release. Tests cover the shared writer fixtures, collisions and migration,
append-only forgetting, missing optional tools, anchoring, marks, installers,
and conversation lifecycle caching.
