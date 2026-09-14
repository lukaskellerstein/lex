<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/lex-logo.png" />
    <source media="(prefers-color-scheme: light)" srcset="docs/logo/lex-logo-light.png" />
    <img src="docs/logo/lex-logo-light.png" alt="Lex" width="340" />
  </picture>
</p>

<p align="center">
  <strong>Your code remembers the AI conversations that talked about it.</strong>
</p>

<p align="center">
  <a href="https://github.com/lukaskellerstein/lex"><img src="https://img.shields.io/badge/version-0.1.0-blue?style=flat-square" alt="Version" /></a>
  <a href="https://neovim.io/"><img src="https://img.shields.io/badge/Neovim-0.11+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Neovim" /></a>
  <a href="https://www.lua.org/"><img src="https://img.shields.io/badge/Lua-5.1_LuaJIT-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" /></a>
  <a href="https://www.typescriptlang.org/"><img src="https://img.shields.io/badge/TypeScript-5-3178C6?style=flat-square&logo=typescript&logoColor=white" alt="TypeScript" /></a>
  <a href="https://bun.sh/"><img src="https://img.shields.io/badge/Bun-1.x-FBF0DF?style=flat-square&logo=bun&logoColor=black" alt="Bun" /></a>
  <a href="https://github.com/folke/snacks.nvim"><img src="https://img.shields.io/badge/snacks.nvim-picker-8FB4F0?style=flat-square" alt="snacks.nvim" /></a>
  <br />
  <a href="https://www.anthropic.com/claude-code"><img src="https://img.shields.io/badge/Claude_Code-hook-D97757?style=flat-square&logo=anthropic&logoColor=white" alt="Claude Code" /></a>
  <a href="https://github.com/openai/codex"><img src="https://img.shields.io/badge/Codex-hook-412991?style=flat-square&logoColor=white" alt="Codex" /></a>
  <a href="https://opencode.ai/"><img src="https://img.shields.io/badge/OpenCode-plugin-EACB4A?style=flat-square&logoColor=black" alt="OpenCode" /></a>
  <a href="https://github.com/tmux/tmux"><img src="https://img.shields.io/badge/tmux-optional-1BB91F?style=flat-square&logo=tmux&logoColor=white" alt="tmux" /></a>
  <a href="https://github.com/lukaskellerstein/lex/actions/workflows/tests.yml"><img src="https://github.com/lukaskellerstein/lex/actions/workflows/tests.yml/badge.svg" alt="Tests" /></a>
  <a href="#licence"><img src="https://img.shields.io/badge/licence-MIT-green?style=flat-square" alt="Licence" /></a>
</p>

<p align="center">
  <a href="#set-it-up">Set It Up</a> &middot;
  <a href="#use-it">Use It</a> &middot;
  <a href="#what-the-marks-mean">The Marks</a> &middot;
  <a href="#commands">Commands</a> &middot;
  <a href="#configure-it">Configure</a> &middot;
  <a href="#how-it-works">How It Works</a> &middot;
  <a href="#status">Status</a>
</p>

---

Your agent understands your code for one hour. Then the session scrolls away.
The code keeps the change and loses the reason.

Lex keeps the reason. Select some lines, paste them into Claude Code, Codex or
OpenCode, ask your question. Weeks later those lines still carry a mark in
Neovim, and one keypress takes you back into the conversation that talked about
them, running or finished.

```
  12 │ export function login(user: User) {      ▎ 💬 3
  13 │   return retry(() => post("/auth", user))
  14 │ }
```

Three conversations talked about these lines. Press one key and you are in one.

![Lex marks and conversation picker](docs/demo.svg)

Nothing about your day changes. Your Neovim config stays yours. The agent stays
in its own terminal tab. The conversation stays in the agent's own history. Lex
is only the memory between the two.

---

## Set it up

Three steps, about two minutes.

### 1. Install the plugin

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "lukaskellerstein/lex",
  dependencies = { "folke/snacks.nvim" },
  event = "VeryLazy",
  opts = {},
  keys = {
    { "<leader>ap", "<cmd>LexCopy<cr>", mode = { "n", "x" }, desc = "📌 Pin Lex Place" },
    { "<leader>al", "<cmd>LexLinks<cr>", desc = "💬 Lex conversations here" },
  },
}
```

`opts = {}` is the whole configuration. Every option has a default.

### 2. Wire your agent

Once, from inside Neovim:

```vim
:LexInstallHook            " Claude Code
:LexInstallHook codex      " Codex
:LexInstallHook opencode   " OpenCode
```

Run it for each agent you use. It edits that agent's own config file, writes
absolute paths, and is safe to run twice.

| Agent | Takes effect |
|:--|:--|
| Claude Code | in your next session |
| Codex | start `codex` once and press `t` to trust the hook |
| OpenCode | the next time OpenCode starts |

### 3. Check it

```vim
:checkhealth lex
```

It reads each agent's config, runs the writer once into a throwaway store, and
tells you how long the hook took.

That is the whole setup. There is nothing to run in the background, no daemon, no
account, no index to build.

---

## Use it

1. **Select lines** in a buffer. Or stand on one line. Or pick a file or a folder
   row in the explorer.
2. **Press `<leader>ap`.** The lines turn blue with a `📌 1` badge: copied, not
   sent yet.
3. **Paste into your agent** and type your question around it. Paste a second
   place if the question needs two.
4. **Send.** The blue turns yellow. That is the proof the link was written.
5. **Later**, on any of those lines, press `<leader>al` and then `<CR>`.

`<CR>` finds the agent wherever it is, any tmux session, any terminal, any
desktop, and takes you there. If the session has stopped, you pick where to
start it again and Lex resumes it for you.

What you copy is a tagged block, so the agent reads real code:

```xml
<lex-place n="1" path="/abs/aaa/src/auth.ts" repo="/abs/aaa" file="src/auth.ts" lines="12-15" lang="typescript">
export function login(user: User) {
  return retry(() => post("/auth", user))
}
</lex-place>
```

You never type that. You never edit it. Paste it and ask your question.

---

## What the marks mean

| Phase | Colour | Sign | Badge |
|:--|:--|:--|:--|
| selecting | blue, nvim's own Visual | | |
| **pending**: copied, not sent | faint blue wash | dashed `┆` | `📌 1`, your own number |
| **history**: the link is written | yellow wash | solid `▎` | `💬 3` |
| the session is answering right now | green | | `working…` |

Put the cursor inside a marked range and the badge grows to show the newest
prompt and its age. Nothing moves, no line is inserted. Where ranges overlap the
wash goes one tone deeper and the sign column shows two bars.

Files change all day, so a link can be in one of four states:

| State | What happened | What you get |
|:--|:--|:--|
| `ok` | the code is where it was | the mark |
| `moved` | the code is elsewhere in the file, or edited | the mark, on the code |
| `orphaned` | the code is gone | no mark, still in the list, greyed, with the code the conversation saw |
| `gone` | the agent deleted its transcript | listed, nothing to open |

A link never points at code the conversation did not see. Lex finds your lines
again by their text, never by their old line number.

---

## Commands

| Command | What |
|:--|:--|
| `:LexCopy` | pin this place and copy it for an agent |
| `:LexLinks` | the conversations on the row under the cursor |
| `:LexLinks file` | the conversations in this file |
| `:LexLinks repo` | everything the agents talked about in this project |
| `:LexWash` | the line wash on or off, for quiet reading |
| `:LexClear` | forget the copied, unsent places |
| `:LexInstallHook [claude\|codex\|opencode]` | wire the writer into an agent |
| `:checkhealth lex` | is it all installed, and how fast is the hook |

---

## The list

One row is one conversation: the session, the agent, the age, what it holds
here, and where its agent is open right now. The preview is the conversation as
it happened, turn by turn, with the places each prompt carried.

| Key | What |
|:--|:--|
| `<CR>`, double click | go to the agent |
| `g` | go to the lines |
| `d` | forget this conversation, or every selected one, after a confirm |
| `<Tab>` | select a row |
| `/` | search |
| `q` | close |
| `?` | every key, snacks' own too |

The bottom border of the list shows these keys, as many as fit. The list opens
on the rows, not in the search, so every key works at once.

`d` removes Lex's memory of a conversation. It never touches the agent's own
history.

To forget every link of one file, for example from a right-click on an explorer
row, call `require("lex.picker").forget_file(path)`. Each conversation loses
only its places in that file. A conversation with no place left disappears from
every list, because Lex keeps no conversation apart from its places.

---

Everything below is optional.

---

## Configure it

```lua
require("lex").setup({
  wash = true,        -- the line background under a linked range
  icon = "💬",
  pin = "📌",
  colors = {
    lex = "#EACB4A",                             -- the product colour
    tone = { "#2F2C1B", "#3D381F", "#4B4423" },  -- the wash, deeper on overlap
    running = "#66AD93",
    pending = "#8FB4F0",
  },
  agents = {
    claude = { name = "Claude Code", resume = { "claude", "--resume" } },
    codex = { name = "Codex", resume = { "codex", "resume" } },
    opencode = { name = "OpenCode", resume = { "opencode", "-s" } },
  },
  opener = nil,    -- fun(t): your machine's own way to a session's window
  where = nil,     -- fun(loc, snap): what only your machine knows, for the list
  terminal = nil,  -- nil tries Ghostty, WezTerm, kitty, Alacritty, $TERMINAL,
                   -- Terminal.app; a name picks one; a function does it your
                   -- way; false hides the "new terminal" entry
})
```

A fourth agent is one more entry in `agents`, plus a writer that speaks the
contract.

`$LEX_HOME` moves the store away from `~/.lex`.

---

## A count in the statusline

A lualine component, `💬 9/12`: the conversations still anchored in this file,
and the ones in the whole project. Left click opens the file, right click opens
the project.

```lua
{
  function() return require("lex.statusline").component() end,
  on_click = function(_, button) require("lex.statusline").click(button) end,
}
```

## A count in the file tree

The snacks explorer, in its `format` hook, asks Lex about each visible row: the
count, `?N` for lost ones, the pin for a pending row, and the wash.

```lua
local lex = require("lex.explorer")
local info = lex.info(path, is_dir)   -- per row
-- lex.chunks(info)  → extmark chunks, right-aligned next to the git letter
-- lex.wash(info)    → a line_hl_group name, or nil
```

A whole file or a whole folder is a place too: pick the row in the explorer and
pin it. A folder place is one block however many files are under it, and it
marks every one of them.

---

## A right-click item instead of a key

`:LexCopy` and `require("lex").copy()` are the same call. It reads the current
selection, the cursor line, or the explorer rows under the mouse, so one menu
item covers every surface:

```lua
for _, mode in ipairs({ "n", "x" }) do
  vim.cmd(mode .. "noremenu PopUp.📌\\ Pin\\ Lex\\ Place <Cmd>LexCopy<CR>")
end
```

Two details, both learned the hard way. Use `nnoremenu` and `xnoremenu`, never
one `anoremenu`: the `a` form wraps the Visual variant in `<C-C>`, which ends
Visual before the command runs, and then there is no selection left to copy. And
use `<Cmd>`, which keeps the mode alive.

If you would rather build the block yourself:

```lua
local place, pending = require("lex.place"), require("lex.pending")
local p = place.for_buffer(buf, from, to)   -- or place.for_path(path)
p.n = pending.add(p)
vim.fn.setreg("+", place.block(p))
vim.notify("Lex: copied " .. place.describe(p))
```

---

## How it works

Two halves live in this repository.

| Half | What it does | Where |
|:--|:--|:--|
| **The writer** | a hook inside the agent. It runs on every prompt, finds the `<lex-place>` blocks in it, and appends one record per place | `agents/` |
| **The reader** | `lex.nvim`. It paints the marks, counts the conversations, and takes you back into one | the repo root |

The writer is small and strict. It never fails your prompt, never prints to
stdout, and runs no git or network. It is a single Lua file run by `nvim -l`
for Claude Code and Codex, and a TypeScript plugin for OpenCode.

```
~/.lex/<readable-repo>--<hash>/links.jsonl  records and forget markers
~/.lex/sessions/<session>.json             live session state
~/.lex/hook.log                            writer failures, if any
```

The hash prevents different repository paths from sharing a store. Upgrading
from 0.1.0 incrementally imports matching records from the old lossy folder and
leaves the old file in place. Forgetting appends a small marker, so it cannot
overwrite a prompt another agent writes at the same moment.

`contract/` keeps the three writers equal. Run the complete suite with:

```sh
sh tests/run.sh
```

Every Lua test runs headless under `nvim -l`; the OpenCode writer test runs under
Bun when Bun is available. The store format, session lookup, re-anchoring, and
writer contract are described in [the architecture guide](docs/architecture.md).

---

## Compatibility

| Component | Supported / tested |
|:--|:--|
| Neovim | 0.11+; CI tests 0.11 and the current stable release |
| OS | macOS and Linux; Windows is not yet supported |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | required for the conversation picker; no minimum version pinned yet |
| Claude Code | hook contract and installer tested; 2.1 tested end to end |
| Codex | 0.154 contract and [hook config](https://developers.openai.com/codex/hooks) generation tested; live hook exercise pending |
| OpenCode | 1.18 plugin contract and installer tested; wider live exercise pending |
| tmux | optional; adds pane jumping and tmux resume targets |
| Bun | optional; needed only to run the OpenCode writer test |

Without tmux, Lex can still identify live agent processes and offer supported
terminal launchers. `ps` and `lsof` improve live-session discovery when present;
missing system tools degrade to fewer jump targets rather than an error.

## Data and privacy

Lex is local-only and makes no network requests. The store contains the code
you copy, up to two surrounding lines, absolute paths, the first line of your
prompt, agent session IDs, and transcript paths. By default it lives in
`~/.lex`; set `$LEX_HOME` before starting Neovim and your agents to move it.

Deleting a row with `d` appends a forget marker to Lex's store. It does not
delete the agent's transcript. To erase everything Lex remembers, remove the
store directory after closing Neovim and the agents.

## Uninstall

1. Remove the plugin from your Neovim plugin specification.
2. Remove the Lex hook entries from `~/.claude/settings.json` and
   `~/.codex/config.toml`, and remove
   `~/.config/opencode/plugin/lex.ts` if you installed the OpenCode adapter.
3. Optionally remove `~/.lex` (or `$LEX_HOME`) to delete stored links and
   session state. This is permanent and does not affect agent transcripts.

## Status

Early. The writers, store, marks, picker, installers, and resume flow are covered
by automated tests. Claude Code has also run end to end; Codex and OpenCode have
local contract and installer coverage but still need broader real-world testing.

`PLAN.md` holds the design journal: every decision with its date, what was
measured, what was rejected, and what is still open.

## Licence

[MIT](LICENSE).
