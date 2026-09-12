# The contract

Three programs read the `<lex-place>` block and one reads the records they
write. They live in three languages. This folder is what keeps them equal.

| File | What |
|:--|:--|
| `prompt.txt` | one prompt with every block form, two malformed blocks, and free text around them |
| `records.json` | the records every writer must produce from it, without the session fields |

The tests feed `prompt.txt` to each writer and compare what lands in the
store with `records.json`:

- `tests/hook_test.lua` runs `agents/claude-code/hook.lua` under `nvim -l`,
  as Claude Code and as Codex.
- `tests/opencode_test.ts` calls `agents/opencode/index.ts` the way OpenCode
  calls it.
- `tests/place_test.lua` parses the prompt with `lua/lex/place.lua`, the
  reference parser the editor uses.

## What the prompt covers

| Block | Checks |
|:--|:--|
| `n="1"`, four lines, `"`, `&`, `<` in the body | the body is never escaped; `n` becomes `index` |
| `<lex-place-1>` whose body spells `</lex-place>` | a renamed tag closes only with its own suffix; the body keeps the text; a trailing blank line is not the tail |
| `dir="docs"` self-closing, right before a closed block | the self-closing form wins a tie; nothing is swallowed |
| `we&quot;ird &amp; co` | attribute escapes come back as `"` and `&` |
| `lines="x-y"` | a bad range is skipped and does not count in `of` |
| `<lex-place-2 …>` closed by a bare `</lex-place>` | a mismatched suffix never closes; the text falls through as free text |
| `n="7"` in another repository, a tab and a non-ASCII character in the body | `n` wins over the order even past `of`; a second store file; hashes agree across languages |

## The rules the records follow

- `index` is `n` when the block carries one, else the block's position among
  the accepted blocks, from 1. `of` is the number of accepted blocks.
- `body` is the block's body, byte for byte: never trimmed, never cut. It is
  what the editor finds the lines by after the file changed. A whole-file or
  a folder block has none.
- `before` and `after` are up to 2 raw lines before and after the range,
  read from the file at `path` when the prompt is sent, joined with `\n`.
  They are present only when the file's lines `from`..`to` still equal the
  body (a trailing carriage return on a file line is ignored), and absent at
  the file's first or last line, or when the file is missing. The fixture's
  paths do not exist, so `records.json` carries neither; each writer's test
  makes a real file for them.
- `head` and `tail` are the first and the last non-blank line of the body,
  with leading and trailing ASCII whitespace removed, cut to 200 characters
  (code points, not bytes). A whole-file or a folder block has neither.
- `hash` is FNV-1a, 32 bits, over the body's bytes with every ASCII
  whitespace character (space, tab, newline, vertical tab, form feed,
  carriage return) removed, written as eight lowercase hex digits. Check
  vectors: `""` → `811c9dc5`, `"a"` → `e40c292c`, `"foobar"` → `bf9cf968`.
- `prompt` is the first non-blank line of the text outside the blocks,
  trimmed and cut the same way; `""` when there is none.
- The store file is `$LEX_HOME/<slug>/links.jsonl`, `$LEX_HOME` defaulting
  to `~/.lex`, and `<slug>` is the block's `repo` with every character that
  is not an ASCII letter or digit replaced by `-`.
- The session fields (`at`, `agent`, `session`, `pid`, `pane`, `transcript`,
  `cwd`) are not in `records.json`; each test checks them for its own writer.
- Key order inside a record is not part of the contract. Readers decode.

Change the block in `lua/lex/place.lua`, in `agents/claude-code/hook.lua`,
in `agents/opencode/index.ts`, and here, or in none of them. The reader of
the records is `lua/lex/anchor.lua`; `tests/anchor_test.lua` is the case
table of what it does when a file changes.
