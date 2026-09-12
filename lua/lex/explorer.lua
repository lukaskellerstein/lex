-- lex.explorer: what a file tree row shows for a path.
--
-- Called by the explorer's `format` hook, per visible row per redraw, so it
-- spawns nothing: the repository comes from `lex.links.roots()` (a cached
-- walk to `.git`), the counts from the tables in memory.
--
-- The rules (PLAN.md § The look, Explorer):
--   count     conversations on exactly this file, or on exactly this folder;
--             files under a folder place carry no count of their own
--   lost      of those, the ones whose transcript is gone: `?N`
--   tone      the wash: 1 for a whole-file place or one folder place above,
--             deeper for each folder place nested above; 0 for none
--   folder    a folder place on this very folder: tint the name and the icon
--   pending   a pending place on this path, or on a folder above it

local conv = require("lex.conv")
local links = require("lex.links")
local pending = require("lex.pending")
local place = require("lex.place")

local M = {}

---@class lex.RowInfo
---@field count integer
---@field lost integer
---@field tone integer
---@field folder boolean
---@field pending boolean
---@field pending_n? integer
---@field repo string
---@field rel string

--- The row's facts.
---@param path string absolute
---@param is_dir boolean
---@return lex.RowInfo
function M.info(path, is_dir)
  local repo, root = links.roots(path)
  local rel = place.relative(vim.uv.fs_realpath(path) or path, root)
  local info = { count = 0, lost = 0, tone = 0, folder = false, pending = false, repo = repo, rel = rel }
  -- Conversations, not records: a prompt that carried two places in this
  -- file is one conversation, and so is one that came back an hour later
  -- with a third (lex.conv).
  local own = is_dir and links.on_dir(repo, rel) or (links.repo(repo).by_file[rel] or {})
  local here, lost = {}, {}
  for _, rec in ipairs(own) do
    if links.gone(rec) then
      lost[#lost + 1] = rec
    else
      here[#here + 1] = rec
      if not is_dir and not rec.from then
        info.tone = 1
      end
    end
  end
  info.count, info.lost = conv.count(here), conv.count(lost)
  if is_dir then
    info.folder = info.count > 0
  end
  for _, rec in ipairs(links.above(repo, rel)) do
    if not links.gone(rec) then
      info.tone = info.tone + 1
    end
  end
  local exact, above = pending.for_path(repo, rel)
  local p = exact or above
  if p then
    info.pending = true
    info.pending_n = p.n
  end
  return info
end

--- The chunks to append to a formatted row: the count, and the pin.
--- Right-aligned, so they sit next to the git status letter.
---@param info lex.RowInfo
---@return table[]
function M.chunks(info)
  local cfg = require("lex").config
  local out = {}
  if info.pending then
    out[#out + 1] = { col = 0, virt_text = { { " " .. cfg.pin .. " " .. info.pending_n, "LexPendingBadge" } }, virt_text_pos = "right_align", hl_mode = "combine", priority = 200 }
  end
  if info.count > 0 then
    out[#out + 1] = { col = 0, virt_text = { { " " .. cfg.icon .. " " .. info.count, "LexExplorerCount" } }, virt_text_pos = "right_align", hl_mode = "combine", priority = 201 }
  end
  if info.lost > 0 then
    out[#out + 1] = { col = 0, virt_text = { { " ?" .. info.lost, "LexExplorerLost" } }, virt_text_pos = "right_align", hl_mode = "combine", priority = 202 }
  end
  return out
end

--- The row's wash, if Lex has one: pending, or the tone. The caller decides
--- where it sits in its own precedence list.
---@param info lex.RowInfo
---@return string|nil
function M.wash(info)
  if info.pending then
    return "LexExplorerPending"
  end
  if info.tone > 0 then
    return "LexExplorerWash" .. math.min(info.tone, 3)
  end
  return nil
end

return M
