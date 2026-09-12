-- lex.nvim: a place in a code file remembers the agent conversations that
-- talked about it. See PLAN.md at the repo root for the whole design.
--
-- The modules:
--   lex.place       the <lex-place> block: build, parse, and the repo roots
--   lex.copy        `📌 Copy Lex Place`: the one gesture, buffer or explorer
--   lex.store       where the links live ($LEX_HOME, ~/.lex) and how to read them
--   lex.links       the store in memory: tail reads, a watcher, running and gone
--   lex.anchor      where a record's lines are now: exact, then fuzzy, else orphaned
--   lex.locate      where a session is running now: the process, and its tmux pane
--   lex.conv        a conversation: one session, many places, added over time
--   lex.pending     copied, not yet sent
--   lex.marks       the wash, the bars and the badges in a buffer
--   lex.explorer    the counts and the wash for a file tree row
--   lex.picker      the conversations of a place, in a snacks picker
--   lex.open        back into a conversation: jump, resume, or nothing
--   lex.statusline  the `💬 N` chip
--   lex.install     :LexInstallHook for Claude Code, Codex and OpenCode
--   lex.health      :checkhealth lex
--   lex.json        JSON that keeps key order, for the settings files
--
-- The writers are not modules: agents/claude-code/hook.lua runs under
-- `nvim -l` on every prompt, agents/opencode/index.ts runs inside OpenCode.

local M = {}

---@class lex.AgentSpec
---@field name string       for a window title
---@field resume string[]   the command, the session id is appended

---@class lex.Config
---@field wash boolean                  paint the line background under a linked range
---@field icon string                   the badge glyph
---@field pin string                    the pending glyph
---@field colors table<string, any>     the palette, see below
---@field agents table<string, lex.AgentSpec>
---@field opener? fun(t: { session?: string, agent?: string, pid?: integer, pane?: string }): boolean
---        the machine's own way to a session's window; called first, before Lex's
---        own checks; true when it went there
---@field where? fun(loc: lex.Location, snap?: lex.Snapshot): string|nil
---        what only this machine can say about where a session runs, the
---        desktop for instance; added to the picker's location column. Called
---        once per row with the same machine reading, so use `snap.procs` and
---        `snap.pane_info` rather than asking again, and cache anything else.
---@field terminal? false|string|fun(cmd: string[], dir: string, title: string): boolean
---        how "new terminal" opens a window: nil tries Ghostty, WezTerm, kitty,
---        Alacritty, $TERMINAL, Terminal.app in that order; a name picks one of
---        them; a function does it your way; false hides the entry
local defaults = {
  wash = true,
  icon = "💬",
  pin = "📌",
  colors = {
    lex = "#EACB4A",
    tone = { "#2F2C1B", "#3D381F", "#4B4423" },
    running = "#66AD93",
    running_bg = "#1F2B27",
    pending = "#8FB4F0",
    pending_bg = "#232B36",
    dim = "#6E6E6E",
  },
  agents = {
    claude = { name = "Claude Code", resume = { "claude", "--resume" } },
    codex = { name = "Codex", resume = { "codex", "resume" } },
    opencode = { name = "OpenCode", resume = { "opencode", "-s" } },
  },
  opener = nil,
  where = nil,
  terminal = nil,
}

---@type lex.Config
M.config = vim.deepcopy(defaults)

local function highlights()
  local c = M.config.colors
  local set = vim.api.nvim_set_hl
  for i, bg in ipairs(c.tone) do
    set(0, "LexWash" .. i, { bg = bg })
    set(0, "LexExplorerWash" .. i, { bg = bg })
  end
  set(0, "LexSign", { fg = c.lex })
  set(0, "LexBadge", { fg = c.lex, bg = c.tone[2], bold = true })
  set(0, "LexBadgeText", { fg = c.dim, bg = c.tone[2], italic = true })
  set(0, "LexWorking", { fg = c.running, bg = c.running_bg, bold = true })
  set(0, "LexPendingSign", { fg = c.pending })
  set(0, "LexPendingWash", { bg = c.pending_bg })
  set(0, "LexPendingBadge", { fg = c.pending, bold = true })
  set(0, "LexExplorerCount", { fg = c.lex })
  set(0, "LexExplorerLost", { fg = c.dim })
  set(0, "LexExplorerFolder", { fg = c.lex })
  set(0, "LexExplorerPending", { bg = c.pending_bg })
  set(0, "LexPickerLines", { fg = c.lex })
  set(0, "LexPickerAgent", { fg = c.dim })
  set(0, "LexPickerDim", { fg = c.dim })
  set(0, "LexPickerNote", { fg = c.dim, italic = true })
end

---@param opts? lex.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("lex_colors", { clear = true }),
    callback = highlights,
  })
  require("lex.marks").setup()
end

--- `📌 Copy Lex Place`: the selected lines, the line under the cursor, or the
--- explorer rows under the mouse, as `<lex-place>` blocks on the clipboard.
--- The one call a keymap or a menu item needs.
function M.copy()
  return require("lex.copy").copy()
end

return M
