# Lex — plan

Lex links a place in a code file to the AI agent conversations that talked about
it, and shows those links inside Neovim. It is the code-side sibling of Rex
(`~/Projects/Github/lukaskellerstein/rex`), which does the same for documents.
Rex is a whole app with its own renderer, threads and agent runner. Lex is
deliberately not: the editor is LazyVim, the agent is Claude Code, Codex or
OpenCode in a tmux tab, and Lex only adds the memory between the two.

Written 2026-09-11 from a brainstorm in the mac-setup repo. Second round the
same day, after the visual prototype, a read of Rex, and the runtime
measurements. Decisions carry their date so a later reader knows what was known
when.

## The problem

Today (mac-setup, `modules/nvim/config/nvim/lua/config/ai-ref.lua`) a
right-click in LazyVim offers **🤖 Copy AI Info**: the file path, the line
range and the selected lines, ready to paste into a Claude Code prompt. That
covers the *send* half of Rex. What is missing is the other half:

- the conversation is not stored anywhere that points back at the file;
- from a file there is no way to see which conversations talked about which
  lines;
- from a line there is no way to jump into that conversation, running or
  finished.

Claude Code does keep every session on disk (`~/.claude/projects/<slug>/*.jsonl`),
but as one JSONL line per message, up to ~150 KB a line, keyed by working
directory, with pasted text cleaned up later. It is a transcript, not an index.
And it deletes them: `cleanupPeriodDays` (default 30) removes a transcript a
month after its last activity.

## Decisions so far (2026-09-11)

1. **The link is made by a Claude Code hook, not by hand and not by nvim.**
   A `UserPromptSubmit` hook receives `session_id`, `cwd` and the full
   `prompt`. It finds the `<lex-place>` blocks in the prompt and appends one
   record per place to the store. The user's gesture does not change: select,
   right-click, copy, paste into any Claude session, type the question.
   Rejected: a manual `/link` step (a step you forget is a link that does not
   exist) and registering at copy time in nvim (places pile up before they are
   used; the hook is still needed for the session id).
2. **The copied block is tagged XML, not a bare header plus code fence.**
   The reason is Lex's own: the hook needs an exact grammar, and a tag cannot
   be confused with the question typed around it. (Corrected 2026-09-11: Rex's
   prompts are plain Markdown with `##` headings, not tags. `src/main/agent/
   prompts.ts` has no `<rex-` string. The earlier claim that Rex "learned
   this" was wrong; the decision stands without it.)
3. **The store is `~/.lex/`, at the user level, not inside any repo.** Same
   choice Rex made with `~/.rex/`. A worktree session and the main checkout
   must see the same store, so the key is the main repository root, not the
   checkout the file was copied from.
4. **Claude Code needs nothing new.** No skill, no command. The one optional
   extra costs nothing: the same hook can return `additionalContext` naming the
   earlier sessions on the same lines.
5. **Start with text selection.** Hierarchy selection (function, class,
   Markdown section) is step two. `<C-space>` incremental selection is gone in
   LazyVim 16 (nvim-treesitter `main` branch dropped the module); `vaf` and
   `vac` exist; a "widen to parent node" key is ~15 lines with
   `vim.treesitter.get_node():parent()`.
6. **Visuals first.** Done: `prototype/marks.lua` and the click-through mockup
   (see *References*) decided the look on 2026-09-11. See *The look*.
7. **One source repo, three writers, published per agent.** Decided
   2026-09-11 (Lukas: one git repo; the first gut was one repo per agent).
   The reader `lex.nvim` sits at the root; `agents/claude-code`, `agents/codex`
   and `agents/opencode` hold the writers. Each writer is published the
   agent's own way from its folder: the Claude Code marketplace takes a
   `git-subdir` source with a `path`, npm publishes a folder, Codex takes a
   `hooks.json`. One contract, one fixture, one version; lazy.nvim clones the
   repo as is and ignores the extra folders. The split by agent is a
   publishing split, not a source split. Move to two repos by role (writers,
   reader) on the day a second reader exists, a VS Code extension for
   example. See *The agents* and *Product split*.
8. **The hook runs as `nvim -l hook.lua`.** Measured 2026-09-11 on nvim
   0.12.2: stdin, `vim.json`, the append and JSON on stdout all work, under
   10 ms a run, user config not loaded, LuaJIT with `vim.uv` and `vim.fs`.
   Rejected: Go, one binary per OS (a release matrix and a download or build
   step, for a program that does one `gmatch` and one append; `apps/inbox` is
   Go because it does real work on every hook, this does not); Python (not on
   Windows by default).
9. **The look: a wash and a bar, no underline.** Every row of a linked range
   gets a line background in the Lex color and a `▎` in the sign column. The
   first row gets a `💬 N` badge, right-aligned. The cursor inside the range
   expands the badge with the newest prompt and its age; nothing moves. Where
   ranges overlap, the wash is one tone deeper and the sign column shows `▎▎`.
   A running session appends `working…` in green. The wash can be turned off
   for reading (`:LexWash`, and a config default); bars and badges stay, so
   the links are still there, only quieter. Rejected: an underline
   (feels wrong, Lukas); a virtual header line above the range (moves the file
   under the cursor); a card float at the cursor (one surface too many; the
   expanded badge and the picker cover it). Rex's own rule was the start:
   nothing painted on the text at rest, the state in a margin bar, the text
   lit only for the comment you stand on (rex, `src/renderer/anchor/
   highlight.ts`, header comment). Lex keeps the wash at rest because a code
   file has no margin lane 18 px wide, and a bar alone in a two-cell sign
   column was too quiet.
10. **The color is a marker yellow, `#EACB4A`.** The product color, on every
    Lex surface. Not blue: Visual is blue in this theme. Not green: git add and
    the explorer's worktree wash are green. It is clear of the two yellows on
    screen, git modified `#E2C08D` (a tan, low saturation) and DiagnosticWarn
    `#CCA700` (darker, olive). The green of `working…` (`#66AD93`, Rex's
    `--ok`) is a state color, not the product color.
11. **Five surfaces, one picker.** The mark; the expanded badge; the
    right-click item `💬 N conversations` on a marked row; the statusline chip
    `💬 N` for the file; the explorer count per file. All three clickable
    things open the same snacks picker, in two scopes: the range (badge, menu
    item) or the file (chip, explorer). `<CR>` opens the session, `g` goes to
    the lines.
12. **One menu item: `📌 Pin Lex Place`.** No *Add Lex Place* in version one:
    a second paste into the same prompt does the same, Claude Code keeps both
    pastes. "Place" is Rex's word for the same thing; the robot said nothing
    about memory. (Named `📌 Copy Lex Place` until 2026-09-14, see decision
    22.)
13. **The record carries the process, the pane and the transcript.** The hook
    sees its parent pid (the `claude` process, measured through `sh -c` and in
    exec form), `$TMUX_PANE` (inherited, the inbox hook already relies on it)
    and `transcript_path` (hook input). With these, "running" is a `kill -0`
    and "jump" is a `tmux select-window`, on any machine. See *The store*.
14. **Four link states, from Rex.** `ok` (the head is at `from`), `moved`
    (found elsewhere in the file), `orphaned` (not found; no mark, still in
    the picker, greyed), `gone` (the transcript file is deleted; no mark,
    listed with the word `gone`, nothing to open). Never fall back to the line
    number when the head is not found: a positional fallback lands on the
    wrong lines and reports success (rex, `src/renderer/anchor/resolve.ts`
    :546-553). One lost place is not a lost conversation (rex, spec 32).
15. **Three agents, one contract.** Claude Code, Codex and OpenCode each
    have a hook that fires on the user's prompt with the full text and the
    session id (researched 2026-09-11, see *The agents*). The `<lex-place>`
    block is plain text and needs nothing per agent. The record gets an
    `agent` field; the reader gets one table per agent: the resume command,
    and how to read the last turn. Running and jump come from `pid` and
    `pane`, the same for all three.
16. **A file and a folder are places too.** From the explorer, `📌 Pin Lex
    Place` on a file row copies the whole-file block (no `lines`, no body),
    on a folder row a folder block (`dir` instead of `file`), and on a
    `<Tab>`-selection one block per row, files and folders mixed. One block
    per folder, however many files: the agent lists it, and the store holds
    one record that applies to every file under it. In a buffer, `ggVG` and
    Pin make a whole-file block too; a body of 400 lines in the prompt
    helps nobody. The look, in a buffer: a bar on every row and no wash
    (Rex: a document is outlined, never filled); the badge on row 1 says
    `whole file`, or `folder docs/` when the place is a folder above. In the
    explorer the wash means whole: a whole-file row is washed; a folder
    place tints the folder's name and icon, carries the count, and washes
    its subtree, the way the worktree wash already shades a subtree in this
    config; a folder place inside another deepens the tone. Files under a
    folder place carry no count of their own, and their picker lists the
    folder's conversations with `folder docs/` in the lines column. Asked by
    Lukas 2026-09-11 after the click-through; Rex has `extent: "document"`
    for the whole file and no folder place.
17. **Three phases, three looks.** Selecting is nvim's own Visual, blue,
    gone the moment you copy. A place copied but not yet sent is *pending*:
    a dashed blue bar `┆` (`#8FB4F0`, Rex's `--link`), a faint blue wash
    `#232B36`, and a `📌 n` badge with no fill, numbered in copy order. A
    place the hook has recorded is history: the solid yellow bar, the yellow
    wash, the filled `💬 N` badge. Shape and color both change (Rex: color is
    never the only signal). The pending list lives in the nvim session,
    never in the store. It clears when the store gains the matching record
    (nvim re-reads on `FocusGained` and on a file watch), when a Pin follows
    a send, or on `:LexClear`. The turn from blue to yellow is the proof that
    the hook wrote the link. Rex's rule, kept: blue is your selection,
    yellow is the past, green is a session at work. Asked by Lukas
    2026-09-11.
18. **Where phases meet, the background belongs to the most recent phase,
    and the bars and badges show every phase.** A pending place over a
    history range: the rows go blue, the sign is `▎┆` in blue (both lanes;
    one sign per slot, one color per sign), and the `💬 N` badges of the
    history ranges stay next to `📌 n`. After the send the rows turn yellow
    and the count goes up. Visual, the most recent phase of all, covers
    both. The same in the explorer: a pending file or folder row is blue,
    a pending folder washes its subtree blue, the yellow name tint of a
    folder place stays (a foreground), and the right slot shows `💬 N` and
    `📌 n`. So the explorer's backgrounds, most recent first: pending, the
    current file, a whole-file or folder place, an open file, the worktree
    wash. Rejected: a blended third color. nvim cannot mix two line
    backgrounds, and a third hex would be a state that means nothing (Rex:
    no seventh hue). Rejected: the past keeps the rows and only the sign
    goes blue. Copying the same range again, the most common repeat, would
    then barely show. Decided with Lukas 2026-09-11.
19. **Three rules from Rex 54, the frame around the text.** Read 2026-09-11
    (rex, `docs/my-specs/54-the-frame-around-the-text/SPEC.md`, in the
    `new-features-test` worktree) and taken: `n`, the user's own number for a
    place, as an optional attribute, so the pending mark `📌 2`, the block
    and the picker say the same "place 2"; attribute values escape `&`, `<`,
    `>` and `"`, and a body never does; and the collision guard: a body that
    spells the tag renames the tag (`lex-place-1`, the smallest suffix the
    body does not spell), and a suffixed tag closes only with the same
    suffix. The old rule, "a body containing `</lex-place>` is not
    supported", was a refusal that fired exactly when Lex reviews its own
    repository. Kept different, on purpose: one flat block per place (the
    paste is the unit; Rex composes one prompt from a list, so it needs a
    document tag), the question as bare text (the user types into the
    agent's own box), `lines="28-28"` for one line (one grammar for three
    parsers), no `whole` attribute (an empty `file` block is already
    unambiguous), and no system-prompt paragraph (decision 4). What already
    agreed: the body is the pick and only the pick, never escaped; a
    selection carries no intent; everything the tool knows is an attribute.
20. **The store stays JSONL, and a record carries the lines.** Lukas asked
    2026-09-12 whether a database (SQLite, DuckDB, Parquet) would serve
    better, because files change under the links all day. Two answers. The
    lines move, the store does not: a record is a photo of what the
    conversation saw, and the editor finds the lines again from the text
    (`lua/lex/anchor.lua`), never writing back; so the store sees one append
    per prompt and no updates, and a file is the one interface a Lua hook, a
    Bun plugin and nvim share for free (Rex has SQLite because one Electron
    process owns it and its rows change). And `head`, `tail`, `hash` alone
    were too weak a key: a rewritten first line orphaned a 20-line link. So
    the record now carries `body`, the block's body byte for byte, and
    `before`/`after`, two raw lines each side read from the file at prompt
    time; the resolver matches exact, then fuzzy at three quarters of the
    strong lines in order, Rex's tolerance. Decided with Lukas 2026-09-12.

21. **A conversation is the unit, not a place.** Lukas, 2026-09-12, after
    the picker listed one prompt with two selections as two rows: "one
    session ID, one coding agent, with multiple selections". A session is
    handed places over time: two in the first prompt, a third ten minutes
    later from another file. So the store stays a record per place per
    prompt, which is all a writer can know, and the reader groups by
    `session` (`lua/lex/conv.lua`): the badge counts conversations, the
    explorer counts conversations, a picker row is a conversation, and its
    preview lists every place that conversation has, marking the ones in
    the current scope. Rex calls this a comment; the two differ because a
    Rex comment can be answered by several agents and a Lex conversation is
    one session of one agent. With it: a repository scope (`:LexLinks
    repo`), the list of everything the agents have talked about in this
    project, and **forget**, the first thing in Lex that is not an append:
    `d` in the picker, or its right-click menu, removes a conversation, or
    one of its places, after a confirm. Decided with Lukas 2026-09-12.

22. **The item is `📌 Pin Lex Place`, not `📌 Copy Lex Place`.** Lukas,
    2026-09-14: the item pins a place more than it copies one. And the popup
    already carries nvim's own `Copy` a few rows lower, so the menu showed
    two items with the same verb. Pin is what the item leaves on screen: the
    `📌 n` badge and the dashed blue bar of a pending place (decision 17).
    The clipboard half is still said, by the notification (`Lex: copied
    …`). Only the label changed; `:LexCopy`, `lex.copy` and the block did
    not. Rejected: *Mark* (the mark is Lex's yellow history bar,
    decision 11, and vim has marks of its own), *Send to Agent* (nothing is
    sent), *Pin for Agent* (drops the name Lex from a shared popup).

Rejected earlier in the same brainstorm, so nobody proposes them again:

| Alternative | Why not |
|:--|:--|
| `coder/claudecode.nvim` (IDE protocol, `provider = "none"`) | Sends selections well, stores nothing. Same gap as today with a different key. |
| `folke/sidekick.nvim` (tmux backend) | One selection per send, launches `claude` itself and skips the worktree wrapper. Stores nothing. |
| Thread files (one Markdown file per question, answered in place by a skill) | Solves storage, but the conversation then lives in a file, not in Claude Code's own history and `/resume`. Lukas wants the sessions, not a second transcript. |
| Teaching Rex to open code files | Two apps, two cursors; Rex stays on documents by decision. |
| Claude's own history as the store + an nvim finder | Finds a whole session, not a place. Worktree sessions scatter over slugs. |
| A Claude Code plugin as the home of the hook | It cannot know where `nvim` is. The nvim plugin can, and writes the absolute path once. |

## The gesture

Unchanged from today, and that is the point:

1. In LazyVim, select lines (or stand on one line, or right-click a file or
   a folder row in the explorer, or `<Tab>`-select several rows).
2. Right-click → **📌 Pin Lex Place**. The clipboard now holds one or more
   `<lex-place>` blocks.
3. Paste into any Claude Code session's prompt. Paste again for a second
   file. Type the question below. Send.
4. The hook records the links. From now on the file shows the mark on those
   lines, and the mark opens the session.

## The template

One block per place. Everything outside the blocks is the question, typed by
the user as free text. The block body is the raw lines, no code fence: the tag
is the fence, and `lang` carries the filetype.

```xml
<lex-place n="1" path="…/aaa/.worktrees/lukas-44/src/auth.ts" repo="…/aaa" file="src/auth.ts" lines="12-15" lang="typescript">
export function login(user: User) {
  ...
}
</lex-place>
```

A whole file (an explorer row, or `ggVG` in a buffer) has no body and no
`lines`:

```xml
<lex-place path="…/aaa/.worktrees/lukas-44/src/auth.ts" repo="…/aaa" file="src/auth.ts"/>
```

A folder (an explorer row) has `dir` instead of `file`. One block for the
folder, not one per file; the agent lists it:

```xml
<lex-place path="…/aaa/.worktrees/lukas-44/src/auth" repo="…/aaa" dir="src/auth"/>
```

| Attribute | Value | Who uses it |
|:--|:--|:--|
| `n` | the user's own number for the place, the one the pending mark shows; optional, first when present | the hook, as `index`; the agent, to say "place 2" |
| `path` | absolute path of the file the selection came from — the worktree copy if that is where nvim runs | the agent's `Read` tool, which takes an absolute path |
| `repo` | absolute path of the **main** repository root: the parent of `git rev-parse --git-common-dir` | the hook, as the store key; works for git worktrees anywhere, not only `.worktrees/` |
| `file` | `path` relative to the checkout root | the hook and nvim, to match a buffer |
| `dir` | a folder, relative to the checkout root, no trailing `/`; never together with `file` | the hook; nvim, to mark every file under it |
| `lines` | `from-to`, 1-based, inclusive, whole lines; a single line is `12-12`; absent for a whole file | nvim, for the mark; the agent, to know where the body sits |
| `lang` | nvim's filetype | the agent |

Rules:

- Whole lines always, also in character-wise Visual, so `lines` and the body
  agree (the rule `ai-ref.lua` already follows).
- nvim computes `repo` at copy time. The hook runs no git and no other process.
- Attribute values are quoted with `"` and escape `&`, `<`, `>` and `"` as
  `&amp;`, `&lt;`, `&gt;`, `&quot;`. A body is never escaped, fenced or
  re-indented: it is the selection, byte for byte.
- A body that spells the tag renames the tag, never the body:
  `<lex-place-1 …>…</lex-place-1>`, with the smallest suffix the body does not
  spell, open or close form. A suffixed tag closes only with the same suffix
  (a back-reference in every parser). Decision 19.
- The grammar is the contract between `lex.nvim` and the hook. Change it in
  both or in neither. `lua/lex/place.lua` is the reference; `tests/
  place_test.lua` holds 35 checks; `contract/` will hold the fixtures the
  writers are tested against.
- The hook takes `index` from `n` when every block in the prompt carries a
  distinct one, else from the order of the blocks; `of` is the count.

## The store

```
$LEX_HOME/<readable-repo>--<hash>/links.jsonl   $LEX_HOME defaults to ~/.lex
```

The readable part collapses every non-ASCII-alphanumeric run to `-`, is capped
at 48 bytes, and is followed by the first 16 SHA-256 hex characters of the
exact `repo`. The hash prevents paths such as `/a-b/c` and `/a/b-c` from
sharing a file. Readers still require the exact `repo` field. Stores from
0.1.0 are copied lazily from their old lossy directory, with exact filtering.
One file per repository keeps reads small. `$LEX_HOME` exists for the tests
and health check, which write into a temporary store.

One JSON object per line, appended by the hook, one per place per prompt:

```json
{"at":1789150926,"agent":"claude","session":"f357503d-15a0-4f23-b026-7f45ddff59c3",
 "pid":59828,"pane":"%212",
 "transcript":"/Users/lukas/.claude/projects/-Users-lukas-Projects-Github-aaa--worktrees-lukas-44/f357503d-….jsonl",
 "cwd":"…/aaa/.worktrees/lukas-44","repo":"…/aaa","path":"…/aaa/.worktrees/lukas-44/src/auth.ts",
 "file":"src/auth.ts","from":12,"to":15,"index":1,"of":2,"lang":"typescript",
 "head":"export function login(user: User) {","tail":"}","hash":"7f3a9c1e",
 "prompt":"Why does login retry twice?"}
```

| Field | What | Who uses it |
|:--|:--|:--|
| `at` | unix seconds | the picker (age) |
| `agent` | `claude`, `codex` or `opencode` | the reader picks the resume command and the transcript reader |
| `session` | the agent's own session id: a UUID (Claude Code), a UUID v7 thread id (Codex), `ses_…` (OpenCode) | resume, the picker |
| `pid` | the `claude` process, the hook's parent | nvim: `working…` needs the session's state file to say `working` and `vim.uv.kill(pid, 0)` to say alive; the pid alone proved nothing, an idle agent waiting for the next prompt is a living process (seen on screen 2026-09-12) |
| `pane` | `$TMUX_PANE` as the hook saw it, or absent outside tmux | the jump: `tmux select-window -t <pane>`; the opener adapter on this machine adds the yabai space |
| `transcript` | `transcript_path` from the hook input (Claude Code, Codex); absent for OpenCode, whose sessions live in SQLite | the picker preview (last turn), and the `gone` state when the file is missing |
| `repo` | from the block; the exact value used to hash the store directory and checked again by readers | a repo-wide picker and collision-safe reads |
| `cwd`, `path`, `file`, `from`, `to`, `lang` | from the block; `from`/`to` absent for a whole file | nvim, the mark |
| `dir` | from a folder block; then `file`, `from`, `to`, `lang`, `body`, `before`, `after`, `head`, `tail`, `hash` are absent | nvim: the record applies to every file under `dir`, and to the folder row in the explorer |
| `body` | the block's body, byte for byte: the lines the conversation saw; absent for a whole file or a folder | re-anchor (`lua/lex/anchor.lua`): exact, then fuzzy; the picker preview when the text is gone |
| `before`, `after` | up to 2 raw lines each side, read from `path` at prompt time, only when the file's lines still equal the body; absent at the file's edges or when the file is missing | re-anchor: pick the right copy when the same lines appear twice, including an identical copy at the old place |
| `index`, `of` | this place's number in its prompt (`n` from the block, else its order), and how many the prompt had | the picker: "place 2 of 3" |
| `head` | the body's first non-blank line, trimmed, cut to 200 characters (code points, not bytes) | re-anchor: nvim searches for it near `from`, then in the whole file |
| `tail` | the body's last non-blank line, same trim and cut | re-anchor: the range end is checked too, not only the start |
| `hash` | FNV-1a, 32 bits, of the body's bytes with every ASCII whitespace character removed, eight hex digits; check vectors in `contract/README.md` | re-anchor: `ok` only if the whole range still hashes the same; else `moved` |
| `prompt` | the first non-blank line of the text outside the blocks, same trim and cut; `""` when there is none | what the picker shows |

- Append-only, one `write()` per record, each record one line. Many sessions
  write at once; a record is never rewritten.
- **Forget** appends a tombstone (`store.forget`, revised 2026-09-12). It names
  a session and optionally one place key, and removes only matching records
  that precede it when read. A later prompt in the same session is visible.
  Because the file is never replaced, a simultaneous writer append cannot be
  lost. The agent's own history is never touched, only Lex's memory.
- The store holds where the text was; the editor finds where it is. A file
  edit never updates a record (*The nvim side*, 1): the current position is
  a value the editor derives from `head`, `tail` and `hash` and keeps in an
  extmark, not in the file.
- `pane` is the pane at prompt time, not a stable identity: the next Claude in
  that pane overwrites it (the inbox learned this). The jump checks `pid`
  first, then uses `pane`.
- A writer that fails appends one line to `$LEX_HOME/hook.log` and still
  exits 0. `:checkhealth lex` reports the file when it exists.
- **The session state**, `$LEX_HOME/sessions/<session>.json`, one small
  file per session, overwritten: `{"state":"working"|"idle"|"ended",
  "at":…,"agent":…,"pid":…,"pane":…,"cwd":…}`. Every writer writes `idle`
  when a session starts or resumes (Claude Code and Codex: `SessionStart`,
  not on a compaction), `working` on the prompt (with or without a block),
  `idle` when the answer ends (`Stop`; OpenCode: `session.idle`), and
  `ended` when the session ends (`SessionEnd`; OpenCode: `dispose`, for
  every session that server touched). The editor takes a session's pid and
  pane from here, not from a record: the record knows the process of the
  prompt's moment, and a session resumed later runs in a new one (the
  first live `<CR>` on a resumed session offered a resume instead of a
  jump, 2026-09-12). The folder is watched, so a `working…` badge goes out
  the moment the answer ends. Added 2026-09-12 after the first screen
  showed `working…` on three idle sessions. A session killed mid-answer
  never writes `idle` or `ended`; the dead pid covers that case.
- `contract/` is the contract between the writers and the reader: one prompt
  with every block form (`prompt.txt`), the records it must give
  (`records.json`), and the rules in words (`README.md`). Every writer's test
  and the reference parser's test read the same two files.

Why a file and not a database (Lukas asked 2026-09-12; measured the same
day): three writers in three languages and one reader share the store, and a
file is the one interface all four have for free. A record is about 640
bytes before the body and 1 to 2 KB with it; 20 places a day is 5 to 15 MB
a year per repository. Reading and decoding 10,000 records of the smaller
kind takes 16 ms, 100,000 takes 159 ms, once per session; the
reader then keeps a table keyed by file and reads only the tail after the
byte offset it remembers, 0.03 ms per new record. An append is one `write()`
per line, safe with many hooks at once. SQLite would need a binding under
`nvim -l` (none built in; the `sqlite3` binary costs 5 to 10 ms per prompt
and a dependency), a lock discipline across processes (the OpenCode database
taught that lesson), and a reader library in nvim. Parquet is 5 to 10 times
smaller but immutable: an append is a rewrite. Rex uses SQLite because one
Electron process owns it. Revisit when one repository's file passes 50 MB or
when a cross-repository search becomes a feature; even then DuckDB can query
the JSONL in place (`read_json_auto`), so the file stays the truth.

## The agents

Researched 2026-09-11 from the docs and the source of each agent. The
Claude Code facts are measured on this machine; Codex and OpenCode are read,
not run.

| | Claude Code | Codex | OpenCode |
|:--|:--|:--|:--|
| The prompt hook | `UserPromptSubmit`, JSON on stdin | `UserPromptSubmit`, JSON on stdin, hooks on by default | plugin hook `chat.message`, called in-process before the message is saved |
| The session signals | `SessionStart`, `Stop`, `SessionEnd`, the same command; the hook branches on `hook_event_name` | the same three, the same command; a new entry means pressing `t` once more | `session.idle` in the plugin's `event` hook, and `dispose` |
| Fields | `session_id`, `cwd`, `prompt`, `transcript_path`, `prompt_id`, `permission_mode`, `hook_event_name` | `session_id`, `cwd`, `prompt`, `transcript_path`, `turn_id`, `model`, `permission_mode`, `hook_event_name` | `input.sessionID`, `output.parts[].text` (the full prompt), `input.agent`, `input.model` |
| Where the hook is declared | `~/.claude/settings.json`, exec form with `args`, no shell | documented nested `[[hooks.UserPromptSubmit]]` / `[[hooks.UserPromptSubmit.hooks]]` tables in `~/.codex/config.toml`; one shell command; a new command must be trusted once with `t` in the TUI | `~/.config/opencode/plugin/lex.ts` (singular `plugin/`, the folder OpenCode 1.18 reads on this machine), or `plugin: ["opencode-lex"]` in `opencode.json` (npm, installed by Bun at startup) |
| The writer | `agents/claude-code/hook.lua`, run as `nvim -l` | the same Lua file, run as `nvim -l … --agent codex` | `agents/opencode/index.ts`, Bun, writes the JSONL itself |
| Environment | inherited; `$TMUX_PANE` present | a snapshot of the codex process env; `$TMUX_PANE` present | the plugin runs inside the opencode process; `process.env` |
| The parent pid | `claude`, measured 2026-09-11 (`ps -o comm=` on the hook's parent under a real `claude -p`) | the `codex` TUI, or the app-server daemon when a reusable daemon socket exists; not measured | `process.pid`, the opencode process |
| Sessions on disk | `~/.claude/projects/<slug>/<id>.jsonl`; deleted after `cleanupPeriodDays` | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl` | SQLite, `~/.local/share/opencode/opencode.db`; `opencode export <id>` prints a session |
| Resume | `claude --resume <id>`, from any directory; the id stays the same | `codex resume <id>`; **the resumed session gets a NEW id** and a new rollout file, a copy of the old one (measured 2026-09-12), so nothing that matches on the id alone can follow it; a cwd mismatch prompts unless `tui.resume_cwd` is set | `opencode -s <id>`; cross-directory behavior not verified |
| Holds its session file open | no (measured) | yes (measured): `lsof -t <rollout>` names the process | no per-session file |
| A paste | collapsed on screen; full text on submit, measured 2026-09-11 (step 1) | collapsed over 1000 characters; full text on submit, verified in source | collapsed over 3 lines or 150 characters; full text on submit, verified in source |
| Plugin packaging | a Claude Code plugin with `hooks/hooks.json`; a marketplace `git-subdir` source with `path` points at the folder | a Codex plugin can ship `hooks/hooks.json`; skills cannot carry hooks | an npm package, or a local file path in the config |

Notes:

- Claude Code and Codex speak the same shape on stdin, so one Lua file serves
  both. The `--agent` argument names the writer; the payload alone would
  need a guess (`prompt_id` versus `turn_id`).
- Codex's legacy `notify` program is not the writer: it fires after the turn
  and carries every user message of the thread, not the current one.
- Codex hook commands go through a shell. The installer quotes the paths.
- Codex's `pid` can be a daemon, not the TUI. The `working…` state can then
  outlive the session. `pane` plus a check that the pane still runs `codex`
  is the fix, later.
- OpenCode has no transcript file. The picker preview runs `opencode export
  <id>` on demand, one call per selected row.
- OpenCode loads what a plugin file exports as plugins, so `index.ts` exports
  only the plugin factory; the parser stays private and the test goes in
  through `chat.message`, the way OpenCode does.
- Codex rewrites `config.toml` itself (trust hashes, TUI state), so the
  installer appends a block after a backup and never merges; it is idempotent
  by the hook path in the file, as mac-setup's own Codex installer is.

## The hook

- Event: `UserPromptSubmit`. Once per prompt, never on tool calls.
- Input on stdin: `session_id`, `cwd`, `prompt`, `transcript_path` (plus the
  rest, ignored). Environment: `$TMUX_PANE` when started in tmux; the parent
  pid is `claude`.
- Behavior: find every `<lex-place …>…</lex-place>` and `<lex-place …/>`,
  parse the attributes, append the records, exit 0. No places → exit 0 with
  no write. A missing or odd field → skip that place, never fail the prompt.
  Garbage on stdin → exit 0.
- Optional output: `{"hookSpecificOutput":{"additionalContext":"…"}}` listing
  earlier sessions on the same `repo`+`file`+overlapping lines, so Claude
  knows a thread exists before it answers. Off by default in version one.
- Speed budget: it runs on every prompt of every session, and this machine
  runs a dozen or more sessions. Under 50 ms, no network, no git. Measured
  under 10 ms. Claude Code's own timeout for this event is 30 s.
- Hooks run as plain user processes, not in the sandbox (docs, confirmed
  2026-09-11), so writing under `~/.lex/` is free. On this machine the
  analogous writer is `~/.claude/hooks/inbox-state.sh` (mac-setup,
  `modules/claude-code/`), which deliberately reads no stdin for speed; this
  hook must read stdin, which is why it is a program and not a shell script.

**Runtime: `nvim -l`**, decided (decision 8). The settings entry uses the exec
form, which spawns the program with no shell on every OS, including Windows:

```json
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command",
  "command":"/opt/homebrew/bin/nvim",
  "args":["-l","/Users/lukas/.local/share/nvim/lazy/lex.nvim/hook/lex.lua"],
  "timeout":5}]}]}}
```

- `:LexInstallHook` writes that entry into `~/.claude/settings.json`,
  idempotent, with `vim.fn.exepath("nvim")` and the plugin's own path. Not
  `vim.v.progpath`: on this machine that is the Cellar path with the version
  in it, and it breaks on the next brew upgrade. Absolute paths because a
  session started from the desktop app has a shorter `PATH` than a terminal.
- `settings.json` on this machine is a symlink into mac-setup. The installer
  edits the file through the link, never replaces it.
- The Claude installer keeps the settings file the way it found it:
  `lua/lex/json.lua` reads objects as ordered pairs and writes them back
  two-space indented, one item per line, the shape Claude Code itself writes,
  so the diff is exactly the new entry. `vim.json.encode` would put 300
  hand-kept lines on one. An entry that names an older checkout is updated
  in place, not doubled.
- `:checkhealth lex` reports the nvim path, the hook file, each agent's
  entry, the store (repositories, links, `hook.log`), and one dry run of the
  writer with the contract prompt, timed.
- `:LexInstallHook` writes four entries: `UserPromptSubmit`, `Stop`,
  `SessionStart`, and `SessionEnd`; the hook reads `hook_event_name`.
  `:LexInstallHook codex` appends the documented parent and nested handler
  tables for the same four events to `~/.codex/config.toml` after a backup,
  with the command as one shell line plus `--agent codex`; it also recognizes
  Lex 0.1.0's inline-array form to avoid duplicates. `:LexInstallHook opencode` copies
  `agents/opencode/index.ts` to `~/.config/opencode/plugin/lex.ts`, and
  copies again when the source changed. Each is idempotent.
- Measured 2026-09-11: a settings file the installer wrote, given to a real
  `claude -p` with `--settings`, ran the hook; the record reached the store
  with the session's real transcript path, `pid` the `claude` process, `pane`
  the tmux pane. 10 ms for the whole hook, `nvim` start included.
- The lazy spec in mac-setup loads the plugin on `VeryLazy` and on
  `:LexInstallHook`. `lazy = true` alone was not enough: `:checkhealth lex`
  looks for `lua/lex/health.lua` on the runtimepath, and a plugin loaded only
  on require is not there yet.

## The look

The prototype is `prototype/marks.lua` (`:luafile`, then `:LexProto ts`); the
click-through mockup is linked under *References*. The rules, for the code
that follows:

| Element | Rule | nvim |
|:--|:--|:--|
| Wash | every row of the range, tone 1; tone 2 where two ranges cover the row; tone 3 for three or more | `line_hl_group`, priority 5 |
| Bar | `▎` on every row; `▎▎` where ranges overlap (two cells is the sign limit) | `sign_text`, priority 5, below diagnostics at 10, so a warning on the row still wins the slot |
| Badge | `💬 N` at the end of the first row of each distinct range; `N` counts conversations on that exact range | `virt_text_pos = "eol_right_align"`, never over the text |
| Expanded badge | while the cursor stands inside: `💬 N  prompt · age` of the newest conversation | the badge layer is redrawn on `CursorMoved`; the static layer is not |
| Working | `working…` appended to the badge, green, while `pid` is alive | `LexWorking` |
| Orphaned, gone | no wash, no bar, no badge; listed in the picker, greyed | |
| Pending | dashed bar `┆` in blue, blue wash, `📌 n` badge on the first row with no fill. Over history: the rows blue, the sign `▎┆` in blue, every badge kept. In the explorer: the row and, for a folder, its subtree washed blue, `📌 n` at the right next to `💬 N` | a third layer, redrawn on Copy, on `FocusGained`, and on a store change; its wash has the highest priority of the three |
| Whole file, in its buffer | a bar on every row, no wash; badge on row 1: `💬 N  whole file`. A whole-file place adds a lane where it meets a range (`▎▎`), never a tone | the same two layers |
| Folder place, in a buffer under it | the same bar; badge on row 1: `💬 N  folder docs/` | |
| Explorer | a count per file and per folder place, in the right slot next to the git letter; `?N` for lost ones. The wash means whole: a whole-file row is washed; a folder place tints the folder's name and icon and washes its subtree; nested folder places deepen the tone; files under a folder place carry no count of their own. One background per row, most recent first: pending, the current file, a whole-file or folder place, an open file, the worktree wash | the explorer `format` hook: a `line_hl_group` chunk and text chunks |
| Palette | Lex `#EACB4A`; tones `#2F2C1B` `#3D381F` `#4B4423`; working `#66AD93` on `#1F2B27`; pending `#8FB4F0` on `#232B36` | one table, `lex.config.colors` |

Two ranges that start on the same row draw two badges on that row. Rare, and
readable.

## The nvim side (`lex.nvim`)

1. **Marks.** On `BufReadPost`, read the repo's `links.jsonl` (once per
   session into a table keyed by `file`; after that only the tail past the
   remembered byte offset, on `FocusGained` and on the `fs_event`), keep the
   records for this buffer, resolve each one (`ok`, `moved`, `orphaned`,
   `gone`), and set the static layer per *The look*.

   **The lines move; the store does not.** Lukas raised this 2026-09-12:
   five projects, five agents each, files changing all day. A record's
   `from`/`to` are where the text was when the prompt was sent, and only a
   hint where to look first. Nothing is ever written back. The resolver,
   `lua/lex/anchor.lua` (written and tested 2026-09-12, `tests/
   anchor_test.lua` is the case table), finds the text again from `body`,
   `before` and `after`, in layers, the first that succeeds wins (decision
   20; Rex, `resolve.ts`):

   | Layer | Found | State |
   |:--|:--|:--|
   | 1, 2 | the body, line for line, trimmed. Every copy is found; when there are several, `before`/`after` pick, then the nearest to `from`. The old place is not trusted on its own: an identical copy can sit exactly there | `ok` when the pick is at `from`, else `moved` |
   | 3 | fuzzy: the window where at least three quarters of the body's strong lines appear in order, the nearest such window; the range stretches over the body's rewritten edge lines | `moved`, edited: a line added, removed or rewritten inside, or a rewritten first or last line; the badge still sits on the text |
   | 4 | nothing | `orphaned`: no mark, but in the picker, greyed, with the body the conversation saw, one click from the conversation |

   A strong line is longer than three characters and not only punctuation;
   `}`, `end`, `);` and blank lines neither start a search nor count, so a
   file full of braces never claims a link. Layer 3 needs two strong lines; a
   one-line range is exact or orphaned. No positional fallback: a link never
   points at lines that do not say what the conversation saw. A record
   written before the body existed resolves by `head`, `tail` and `hash`,
   with less to go on. Measured 2026-09-12: 50 links in a 5,200-line buffer,
   all shifted by an insert of 200 lines, index and resolve in 2 ms.

   Built 2026-09-12 (`lua/lex/marks.lua`): every repaint resolves each
   record against the buffer as it is now. A text change repaints after a
   300 ms pause; `BufWritePost`, `FileChangedShellPost` and `BufReadPost`
   repaint at once; a store change repaints the repository's buffers. The
   first design here said "the extmarks follow edits by themselves"; they
   do, but a row inserted inside a range would stay unwashed until the next
   resolve, and a resolve is 2 ms, so the paint is simply redone. Whole-file
   and folder places have no lines and never move; a renamed file is
   `orphaned` until step two reads `git log --follow`.
2. **The badge layer.** `CursorMoved` redraws the badges of the ranges in view.
   Cheap: one extmark per range.
2b. **The pending list.** Pin appends `{ file | dir, from, to, n }`.
   `FocusGained` and a `vim.uv.new_fs_event` on the repo's `links.jsonl`
   re-read the store; an entry whose record has arrived is dropped, and the
   yellow mark takes its place. `:LexClear` empties the list. A Pin after
   a send starts a new list at `1`.
3. **The click.** On a marked row the right-click menu gets **💬 N
   conversations**, drawn only when the row has links — the same per-click
   rebuild `ai-ref.lua` uses for *Open in Browser*. A keymap does the same
   from the keyboard. A click on the badge does the same for that range. In
   the explorer the same two items sit on file rows and folder rows: Pin
   makes the whole-file or folder block, and the count opens the picker in
   file or folder scope.
4. **The picker.** A snacks picker, one row per conversation (decision 21),
   in four scopes: the range (from the menu item, the badge, the keymap),
   the file (the statusline chip, the explorer count), a folder (an
   explorer row), and the repository (`:LexLinks repo`, the right click on
   the chip).

   **The row** is the session first, so it can be read and recognised, then
   the agent, the age, what the conversation holds, and where its agent is
   open right now. What it holds is the place in this file for a range or
   file scope (`59-69`, `2 places`, and `of 4 places · 2 files` when it has
   more elsewhere), or `4 places · 2 files` for a folder or the repository.
   Where it is open is `tmux <session>:<window> <name>` for a pane, the
   window's name kept only when it says something (a bare version number,
   which is what Claude Code calls its window, is not), `terminal` for a
   window with no tmux, and `—` when no process has it; `config.where` adds
   what only the machine can know, and on this one that is `desktop 14`,
   from yabai, matching a pane by its terminal's title and a bare window by
   the nearest ancestor that owns one. A word follows only for the abnormal
   case: `working…`, `edited`, `moved`, `lost`, `gone`. No prompt column:
   every prompt is in the preview where it belongs with its own places
   (Lukas, 2026-09-12, "seeing the message as another column is useless").
   Typing still searches the prompts.

   The whole list is placed in one reading of the machine
   (`locate.locate_many`): one `ps`, one `tmux list-panes`, at most one
   `lsof`, one window query. 240 ms for nine rows, against 840 ms when each
   row asked for itself.

   **A picker item's fields are not ours alone.** `loc`, `buf`, `file`,
   `pos`, `end_pos` and `preview` mean something to snacks: it reads
   `item.loc` as an editor location and indexes `loc.range` on every
   `current()`, so Lex's own location under that name was an error on every
   cursor move, which stopped the arrow keys dead (2026-09-12). Ours is
   `running`. A picker driven from a real terminal under tmux is how that
   was found; headless nvim has no window for a picker to draw in.

   **Nothing in the preview may block the list.** Claude Code and Codex
   keep a transcript file and the last 2 MB of it read in a millisecond, so
   those answer at once. OpenCode keeps its sessions in a database, only
   `opencode export` can read them, and that costs 400 ms every time
   (measured 2026-09-12) -- which froze the arrow keys on every OpenCode
   row, because a preview is redrawn on every cursor move. So the OpenCode
   read is asynchronous: the preview says it is reading, and draws itself
   again when the answer lands, if that row is still the one.

   **The preview** is the conversation as it happened: a header, then one
   block per turn, each headed by a band, `turn N · age`, then the prompt,
   then the places that came with that prompt, an arrow on the ones in the
   current scope; then the agent's last answer under its own band. A band
   is a drawn line above and below the title, not a markdown rule: a rule
   under a line of text is a setext heading, and a single rule between two
   blocks reads as belonging to neither, which is what confused Lukas
   2026-09-12 when the agent's own answer carried rules of its own. A turn is the records that
   share a time and a prompt (`lex.conv.turns`), so only the turns that
   carried a place are there, which is all Lex ever sees. The lines
   themselves are not shown: they are in the file, one click away, and they
   crowded out everything else. A place line opens its file at its lines,
   with `<CR>` or a double click.

   `<CR>` or a double click on a row opens the agent, `g` goes to the
   lines, `d` forgets after a confirm, `q` closes. Order: newest first,
   gone last. The right-click inside the picker is the picker's own menu,
   not the buffer's: go to the agent, go to the lines, forget this
   conversation, forget only this place.
5. **Open.** Alive → jump to its pane (the `opener` adapter, then tmux).
   Not alive → the user picks a tmux session or a split here, and a new
   window there runs the agent's resume command: `claude --resume <id>`,
   `codex resume <id>`, `opencode -s <id>`. Gone → a notice, nothing to
   open. See *`<CR>`: back into the conversation* below. The commands live
   in one `agents` table in the config, so a fourth agent is one entry.
6. **Statusline.** A lualine component `💬 9/12`: the conversations that
   still have a place in this file, and the ones in the whole project. Two
   numbers because the file's are a part of the project's and each half is
   what one mouse button opens (Lukas, 2026-09-12). Left click opens the
   file's picker, right click the whole project's, the split the rest of
   Lukas's bar already uses; in a buffer that is not a file it reads
   `💬 -/12` and either button opens the project. The two pickers say which
   one they are right after `Lex`, before a path that can be cut:
   `Lex · this file · tutorial/…/README.md` and
   `Lex · whole project · ai-evaluation` (Lukas, 2026-09-14, "I see on the
   first sight if I see comments just for one file or for all files"); a
   range reads `Lex · line 42 · README.md`, a folder `Lex · folder · docs/`.
   This is the visual way
   into the project-wide list, so nobody has to remember `:LexLinks repo`.
   The project number is cached until the store changes or for 60 seconds,
   whichever comes first. The expiry lets a deleted transcript disappear
   from the count even when the append-only link store did not change.
7. **Explorer.** A count per file and per folder place, in the right slot
   next to the git status letter, through the explorer `format` hook that
   already emits raw chunks there (mac-setup, `plugins/snacks.lua`). `?N`
   for lost ones, Rex's shape. The wash for whole-file rows and folder
   subtrees goes through the same `line_hl_group` chunk the open-file
   shading uses; the folder tint recolors the name and icon chunks the way
   the repo-root purple does.
8. **Step two.** Hierarchy selection (the "widen selection" key); a "forget
   this link" command (appends a tombstone); `additionalContext` on
   by option; a repo-wide picker scope.

### `<CR>`: back into the conversation

Lukas's expectation, stated 2026-09-12 after the first `<CR>` opened a
terminal in the wrong buffer: hit Enter and see the agent this conversation
belongs to, wherever it is: any desktop, any tmux session, any terminal. If
it is not running, a choice of where to start it again. The same for all
three agents. So `lua/lex/open.lua` does:

1. **Gone** (the transcript deleted): a notice, nothing to open.
2. **Find the session, live** (`lua/lex/locate.lua`). A record remembers
   the process and the pane of the prompt's moment; neither survives a
   restart, and a stored pane is worse than nothing once another session
   takes it over (a Codex row opened a different Codex conversation,
   2026-09-12). So a pane is never read from a record. Three proofs, each
   exact, tried in order:

   | | Proof | Catches |
   |:--|:--|:--|
   | 1 | the state file's pid, alive and not `ended` | a session that never left; a Claude Code session resumed from its own picker |
   | 2 | a process **running the agent** whose command line carries the session id: `claude`, `codex` or `opencode` as the program, never a terminal that spawned one and never a shell that merely names it | every resume by id: `claude --resume X`, `codex resume X`, `opencode -s X`, and it still works when the agent renames the session, which Codex does: `codex resume` writes a new rollout with a new id, so the state file can never match the old one (measured 2026-09-12) |
   | 3 | the process holding the session's file open (`lsof`) | Codex only. It keeps its rollout open; Claude Code closes its transcript again and OpenCode has no per-session file, both measured, and `lsof` costs 180 ms whatever it is asked, so those two are never probed |

   The pane then comes from that process's own place in the tree: walk its
   parents and take the **nearest** one that is a tmux pane's process
   (`tmux list-panes -a -F '#{pane_pid} #{pane_id}'`). No pane means the
   agent runs in a terminal window with no tmux; the pid is still the
   answer, and the window is found by the same rule: the nearest ancestor
   that owns one. Nearest, never any: the chain does not stop at the
   session's own terminal, it goes on to whoever launched it, and for a
   terminal Lex opened that is this nvim, whose own ancestors reach the
   terminal app that owns every other window on the desktop. Taking any
   ancestor focused whichever window the window manager listed first
   (2026-09-12: a Claude session opened an unrelated editor window, while
   OpenCode worked only because its window happened to come first).

   Nothing here is per agent. The three differ in their resume command and
   in where their transcript lives, and in nothing else; a fault in the
   jump is a fault for all three, whichever one shows it first.
3. **Found**: `config.opener` gets the session id, the agent, the pid and
   the proved pane, and may do better than tmux. On this machine, in this
   order: the proved pane through `lukas-inbox jump`; else the window yabai
   knows by a pid that is one of the session's own ancestors, which is how
   a session in a terminal with no tmux is reached; else, only when Lex
   found no process at all, the inbox's own lookup by session id, whose
   pane is where the session *used* to be and is checked for a live pid
   first. Proof before memory: the other order sent two OpenCode rows to an
   unrelated pane while a third worked (2026-09-12). Then Lex's own tmux
   jump: `select-window`, `select-pane`, and `switch-client` when nvim runs
   inside tmux; outside, a notice names the session and the terminal is the
   user's to focus.
4. **Not found**: `vim.ui.select` over the places to resume in: "new
   terminal" first, then every tmux session (this one first, then attached
   ones, then the most recently attached). No split inside nvim: Lukas
   dropped it 2026-09-12. A tmux pick runs `tmux new-window -P -F
   '#{pane_id}' -t <session>: -c <cwd> -n <short id> <resume command>` and
   jumps to the new pane the same way, which on this machine means the
   desktop showing that tmux session is focused too: the inbox cannot know
   a pane that is one second old, so the opener falls back to the terminal
   window titled `<session>:…`, and only when no window shows that session
   does it pull the session into the terminal you are in (Lukas,
   2026-09-12: the tab was created and nothing took him to it). The window
   is named after the first eight characters of the session id, the same the prompt shows, so a row
   of tabs says which conversation is which. "New terminal" tries Ghostty,
   WezTerm, kitty, Alacritty, `$TERMINAL`, Terminal.app in that order,
   started detached with `TMUX` and `TMUX_PANE` removed from the
   environment, the lesson mac-setup's inbox learned; `config.terminal`
   names one of them, or is a function to do it another way, or `false` to
   hide the entry. Never `split` and then `jobstart`: that turned the
   buffer under the cursor into the terminal (seen 2026-09-12).
5. Found but not reachable (no pane and no opener, or tmux does not know
   it): the same chooser, with a line that says where it runs and why the
   jump failed.

Measured against the real store, 2026-09-12: of ten records, three Claude
Code sessions were found at panes other than the one stored (one by its
state file, two by `claude --resume` on the command line), one Codex
session by the process holding its rollout (stored `%354`, really `%346`),
one OpenCode session by its state file, one OpenCode session by
`opencode -s` in a Ghostty window with no tmux at all, and three were
correctly reported as not running.

### The `opener` adapter

Default, portable: tmux, as above. On this machine: `lukas-inbox jump
<pane>` (mac-setup, `apps/inbox`; the key is the pane id with its `%`),
which also focuses the yabai space and the window and marks the session
seen. The inbox's own state files (`~/.local/state/agent-inbox/*.state`) are
not needed for "alive"; `pid` answers that.

## Product split

| Part | Where |
|:--|:--|
| Template, the clipboard item | `lex.nvim`, the repo root |
| The contract: the record, a fixture prompt, a fixture `links.jsonl` | `contract/`, tested by every writer and by the reader |
| The Claude Code and Codex writer (`hook.lua`) | `agents/claude-code/`, a Claude Code plugin folder; Codex reuses the file |
| The OpenCode writer (`index.ts`) | `agents/opencode/`, an npm package folder |
| The installers, `:checkhealth lex` | `lex.nvim` |
| Marks, badges, picker, statusline, explorer, resume | `lex.nvim` |
| `repo` from the git common dir | `lex.nvim` |
| Jump to a running session | `opener` option, default tmux; `lukas-inbox jump` on this machine |
| Worktree launch wrapper (`claude -w`) | mac-setup `modules/zsh`, not Lex |
| Publishing | `claude-my-marketplace` points at `agents/claude-code` with `git-subdir`; npm publishes `agents/opencode`; Codex users copy one `hooks.json` entry |

The audience is people who run Claude Code next to nvim in a terminal. The
existing plugins in that space send a selection; none remembers where a
conversation came from.

## Steps, in order

1. ~~**Measure**~~ Done 2026-09-11: `prompt` holds the full pasted block. A
   `<lex-place>` paste of 416 characters, shown on screen as
   `[Pasted text #1 +8 lines]`, reached a throwaway `UserPromptSubmit` hook
   (`claude --settings <file>`, exec form, `nvim -l`) as the block plus the
   question typed under it. No fallback to the transcript is needed. Codex
   and OpenCode: full text on submit, read in their source, not run.
2. ~~**Visual prototype**~~ Done 2026-09-11. `prototype/marks.lua` stays as
   the reference until the real module replaces it.
3. ~~**Template**~~ Done 2026-09-11. The block lives in lex.nvim from the
   start (`lua/lex/place.lua`: build, parse, the repo roots, 20 checks in
   `tests/place_test.lua`), not in mac-setup, so the writers' fixtures can
   test the real builder and step 6 has nothing to move. mac-setup got the
   four-part edit: `ai-ref.lua` calls `lex.place` and names the item
   `📌 Copy Lex Place`; `plugins/lex.lua` loads the local checkout on the
   first require; the cheatsheet and config-decisions carry the change.
4. ~~**Hook, store, installer**~~ Done 2026-09-12. `agents/claude-code/
   hook.lua` (Claude Code, and Codex with `--agent codex`),
   `agents/opencode/index.ts`, `lua/lex/store.lua`, `lua/lex/install.lua`
   (`:LexInstallHook [claude|codex|opencode]`), `lua/lex/health.lua`,
   `lua/lex/json.lua`, `contract/` (the prompt, the records, the rules in
   words), five test files, 235 checks (`sh tests/run.sh`). Measured end to
   end through a real `claude -p` with a settings file the installer wrote.
   Not run live yet: Codex (the trust gate) and OpenCode (the plugin load);
   the installers were not run on this machine's real settings. The Claude
   Code plugin form (`agents/claude-code/hooks/hooks.json`, `nvim` from
   PATH) is written for publishing and untested.
5. ~~**Marks, badges, click, picker, open, statusline, explorer**~~ Built
   2026-09-12, live test pending. lex.nvim: `lua/lex/links.lua` (the store
   in memory, tail reads, a folder watcher, `running`, `gone`, `age`, and
   `roots()` without git), `pending.lua`, `marks.lua` (the three layers,
   `count_at`, `records_at`, `:LexWash`), `explorer.lua` (`info`, `chunks`,
   `wash` for a tree row), `picker.lua` (three scopes, the transcript tail
   as preview, `<CR>` open, `g` go), `open.lua` (jump through
   `config.opener` or tmux, else resume in a new tmux window, else a
   terminal split), `statusline.lua`, `:LexLinks [file]`, `:LexClear`;
   `tests/marks_test.lua`, 71 checks with real extmarks, headless. mac-setup:
   `ai-ref.lua` numbers a copy through the pending list and draws
   `💬 N conversations` per click; `snacks.lua` asks `lex.explorer` per row
   for the count, the lost count, the pin, the wash and the folder tint;
   `statusline.lua` carries the chip; `plugins/lex.lua` passes the
   `lukas-inbox jump` opener. Checked headless on the real store: the
   record from Lukas's first prompt resolves and paints in `main.py`. Not
   yet seen on a screen: the explorer row, the statusline chip, the picker,
   the resume. No keymap yet; the right-click and `:LexLinks` are the ways
   in.
6. **Docs**, and the move of the menu item out of `ai-ref.lua` into
   `lex.nvim`, so a user without this config gets the same right-click. The
   template itself already lives in lex.nvim (step 3).

## Open questions

- `claude --resume <id>` when the session's worktree has been deleted:
  not measured. The docs say resume works from any directory and searches
  across worktrees. From the main folder it snaps back into the worktree when
  the worktree exists (mac-setup, `projects/claude-code.md` § Worktrees).
- `cleanupPeriodDays`: raise it on this machine, or accept `gone` links after
  30 days? The link record survives either way.
- The sign slot: is priority 5 (below diagnostics) right, or does a Lex bar
  matter more than a hint sign? Decide when the real marks exist.
- The wash under `CursorLine`: which wins on the cursor row, and does it
  matter with the caret and `CursorLineNr` visible? Check in the prototype.
- Visual over the wash: does Visual's blue cover the yellow line highlight
  while you select inside a marked range? Expected yes. Check with `V` in
  the prototype.
- Codex behind a daemon: is the hook's parent the TUI or the app-server on
  this machine? The writer exists; measure on the first live Codex run.
- The two live runs still owed: after `:LexInstallHook codex`, start codex,
  press `t`, send one prompt with a block, look for the record; after
  `:LexInstallHook opencode`, restart OpenCode and do the same. The parsers
  are tested against the contract; the wiring into those two agents is not.
  Claude Code ran live 2026-09-12 and its records paint.
- The transcript tail in the picker preview: the Claude Code shape is read
  from a real transcript; the Codex rollout shape (`response_item` with
  `payload.content[].text`) and `opencode export` are read from memory of
  their formats, not run. Check on the first live picker of each.
- `pid` reuse: a session's process id can be taken by another process
  after the session ended, and `working…` would lie. Rare within a day;
  a check that the pid still runs the agent is the fix, later.
- OpenCode: does `chat.message` fire for a subagent's prompt too? A block
  the model copies into a subagent prompt would then link the child session.
- `opencode -s <id>` from another directory: does it find the session?
- OpenCode has no transcript file, so `gone` needs another test there:
  `opencode session list --format json`, or a failed `export`.

## References

- This repo: `prototype/marks.lua` (the look, runnable), the click-through
  mockup <https://claude.ai/code/artifact/37dfde78-b26c-4703-8b5e-21fa193373b4>.
- mac-setup: `modules/nvim/config/nvim/lua/config/ai-ref.lua` (the current
  item, the whole-line rule, the per-click menu rebuild),
  `modules/nvim/config/nvim/lua/plugins/snacks.lua` (the explorer `format`
  hook, raw extmark chunks), `modules/nvim/config/nvim/lua/plugins/
  colorscheme.lua` (the palette the tones were derived from),
  `modules/claude-code/home/.claude/hooks/inbox-state.sh` (a hook on the same
  speed budget; `$TMUX_PANE` and `$PPID` measured there), `apps/inbox`
  (`lukas-inbox jump`), `notes/config-decisions.md` § "Right-click → Copy AI
  Info".
- Rex: `src/renderer/anchor/highlight.ts` (nothing painted at rest, the
  header comment), `src/renderer/overlay/marginLane.ts` and `MarginBars.tsx`
  (the bar, the second lane on overlap), `src/renderer/overlay/wash.ts` (a
  selection deepens the wash, never changes hue), `src/renderer/anchor/
  resolve.ts` (the anchor layers, no positional fallback), `src/shared/
  types.ts` (`Anchor`, `AnchorTarget`), `src/main/db/schema.sql`
  (`thread_target`), `docs/my-specs/15-the-working-copy` § 8, `18-what-the-
  colours-mean`, `32-one-lost-place`, `33-the-comment-row`.
- Claude Code docs: hooks reference (`UserPromptSubmit` input and
  `additionalContext`; the exec form with `args`; hooks run outside the
  sandbox; 30 s timeout on this event), plugins reference (`hooks/hooks.json`,
  `${CLAUDE_PLUGIN_ROOT}`), plugin marketplaces (`git-subdir` with `path`),
  sessions (`--resume` from any directory), settings (`cleanupPeriodDays`,
  `--settings` merges).
- Codex: <https://learn.chatgpt.com/docs/hooks> (events, stdin JSON, the
  `UserPromptSubmit` schema), the CLI reference (`codex resume`), and in the
  source `codex-rs/hooks/` (registry, command runner, legacy notify),
  `codex-rs/rollout/` (session paths), `codex-rs/tui/src/bottom_pane/
  chat_composer.rs` (paste expansion).
- OpenCode: <https://opencode.ai/docs/plugins/> (hooks, `chat.message`,
  events), <https://opencode.ai/docs/cli/> (`-s`, `session list`, `export`),
  and in the source `packages/plugin/src/index.ts` (the hook types),
  `packages/opencode/src/session/prompt.ts` (where `chat.message` fires),
  `packages/tui/src/component/prompt/index.tsx` (paste expansion).
- Looked at and rejected: `coder/claudecode.nvim`, `folke/sidekick.nvim`,
  `mr55p-dev/claude-tmux.nvim`.
