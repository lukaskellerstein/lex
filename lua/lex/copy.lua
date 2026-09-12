-- lex.copy: `📌 Copy Lex Place`, the one gesture the user makes.
--
-- One entry point, two surfaces, dispatched on the buffer:
--
--   * a file buffer -- the selected lines; with nothing selected, the line
--     under the cursor; the whole buffer becomes a whole-file place
--   * a snacks picker list, the explorer mainly -- the clicked row, or every
--     `<Tab>`-selected row, one block each: a file is a whole-file place, a
--     folder is a folder place (`dir=`, every file under it, one block)
--
-- The block goes to `+` and to `"`. Both, because `setreg('"', …)` does not
-- sync onward to `+` the way a real yank does, and `clipboard=unnamedplus`
-- does not change that.
--
-- Each place is numbered through `lex.pending` first, and the number rides in
-- the block as `n`. So the blue `📌 2` in the margin and "place 2" in the
-- store and in the agent's reading all say the same thing.
--
-- The selection is left in place for a picker, unlike `y`: copying is a read,
-- and an `m` or a `d` on the same rows may well follow. In a buffer Visual
-- ends, the way the built-in Copy does.
--
-- Lived in mac-setup's `config/ai-ref.lua` until 2026-09-12, so a user
-- without that config had to write it again. PLAN.md step 6.

local place = require("lex.place")
local pending = require("lex.pending")

local M = {}

local function notify(msg, level)
  vim.notify("Lex: " .. msg, level or vim.log.levels.INFO)
end

local function to_clipboard(text)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
end

local function in_visual()
  return vim.fn.mode():find("^[vV\22]") ~= nil
end

--- Any picker list, not only the explorer's: a path is a path. Items without
--- one (a command, a keymap) are skipped.
---@param buf integer
local function picker_for(buf)
  if not _G.Snacks or not Snacks.picker then
    return nil
  end
  for _, p in ipairs(Snacks.picker.get({})) do
    if p.list.win.buf == buf then
      return p
    end
  end
end

---@param buf integer
local function copy_picker(buf)
  local picker = picker_for(buf)
  if not picker then
    return notify("no picker owns this window", vim.log.levels.WARN)
  end
  -- A Visual range over rows becomes a selection first. `list:select()` with
  -- no item reads the range itself and ends Visual mode, so it must be called
  -- while still IN Visual, which a `<Cmd>` mapping preserves.
  if in_visual() then
    picker.list:select()
  end
  local blocks, last = {}, nil
  for _, item in ipairs(picker:selected({ fallback = true })) do
    local path = Snacks.picker.util.path(item)
    if path then
      last = place.for_path(path)
      last.n = pending.add(last)
      blocks[#blocks + 1] = place.block(last)
    end
  end
  if #blocks == 0 then
    return notify("nothing with a path under the cursor", vim.log.levels.WARN)
  end
  to_clipboard(table.concat(blocks, "\n"))
  if #blocks == 1 then
    notify("copied " .. place.describe(last))
  else
    notify(("copied %d places"):format(#blocks))
  end
end

---@param buf integer
local function copy_buffer(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  -- A terminal, a scratch buffer, a file never saved: the agent can only read
  -- what is on disk.
  if path == "" or not vim.uv.fs_stat(path) then
    return notify("this buffer has no file on disk", vim.log.levels.WARN)
  end

  local from, to
  if in_visual() then
    from, to = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
    if from > to then
      from, to = to, from
    end
    -- Pressing the mode's own key is the exit that works for `v`, `V` and
    -- CTRL-V alike, and it is synchronous, unlike feeding <Esc>.
    vim.cmd("normal! " .. vim.fn.mode():sub(1, 1))
  else
    from = vim.api.nvim_win_get_cursor(0)[1]
    to = from
  end

  -- The whole-line rule and the whole-buffer rule both live in lex.place:
  -- `from`..`to` are whole lines already, and 1..$ becomes a whole-file place.
  -- A selection that spells the tag itself is fine: lex.place renames the tag
  -- with a suffix and leaves the body alone.
  local p = place.for_buffer(buf, from, to)
  p.n = pending.add(p)
  to_clipboard(place.block(p))

  local what = place.describe(p)
  if vim.bo[buf].modified then
    -- Worth a warning, not a refusal: the clipboard holds the buffer, the
    -- agent reads the disk, and the two differ until `:w`.
    notify(("copied %s -- unsaved changes, the agent reads the disk"):format(what), vim.log.levels.WARN)
  else
    notify("copied " .. what)
  end
end

--- Copy the place under the cursor, or the selected places, as `<lex-place>`
--- blocks. Works in a file buffer and in a snacks picker list.
function M.copy()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "snacks_picker_list" then
    return copy_picker(buf)
  end
  return copy_buffer(buf)
end

return M
