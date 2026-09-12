-- lex.pending: the places copied and not yet sent.
--
-- `📌 Copy Lex Place` appends one entry and gets its number back; the number
-- goes into the block as `n`, so the pending mark, the block and the record
-- say the same "place 2". When the record arrives in the store, the entry is
-- dropped and the yellow mark takes its place. When the list empties that
-- way, the next copy starts a new list at 1. `:LexClear` empties it by hand.

local M = {}

---@class lex.Pending
---@field n integer
---@field repo string
---@field file? string
---@field dir? string
---@field from? integer
---@field to? integer
---@field at integer

---@type lex.Pending[]
M.list = {}
M.next = 1

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "LexPendingChanged", modeline = false })
end

--- Add a place. Returns its number.
---@param p lex.Place
---@return integer
function M.add(p)
  local e = { n = M.next, repo = p.repo, file = p.file, dir = p.dir, from = p.from, to = p.to, at = os.time() }
  M.next = M.next + 1
  M.list[#M.list + 1] = e
  changed()
  return e.n
end

function M.clear()
  M.list = {}
  M.next = 1
  changed()
end

--- The entries that touch a file: its own, and folders above it.
---@param repo string
---@param file string relative
---@return lex.Pending[]
function M.for_file(repo, file)
  local links = require("lex.links")
  local out = {}
  for _, e in ipairs(M.list) do
    if e.repo == repo and (e.file == file or (e.dir and links.covers(e.dir, file))) then
      out[#out + 1] = e
    end
  end
  return out
end

--- The entry on exactly this path, file or folder, or one on a folder above.
---@param repo string
---@param rel string relative
---@return lex.Pending|nil exact, lex.Pending|nil above
function M.for_path(repo, rel)
  local links = require("lex.links")
  local exact, above
  for _, e in ipairs(M.list) do
    if e.repo == repo then
      if e.file == rel or e.dir == rel then
        exact = exact or e
      elseif e.dir and links.covers(e.dir, rel) then
        above = above or e
      end
    end
  end
  return exact, above
end

--- Drop the entries whose record has arrived in a repository's store.
---@param repo string
function M.on_store(repo)
  local r = require("lex.links").repo(repo)
  local keep, dropped = {}, false
  for _, e in ipairs(M.list) do
    local arrived = false
    if e.repo == repo then
      for i = #r.records, 1, -1 do
        local rec = r.records[i]
        if rec.at < e.at - 1 then
          break
        end
        if rec.file == e.file and rec.dir == e.dir and rec.from == e.from and rec.to == e.to then
          arrived = true
          break
        end
      end
    end
    if arrived then
      dropped = true
    else
      keep[#keep + 1] = e
    end
  end
  if dropped then
    M.list = keep
    if #keep == 0 then
      M.next = 1
    end
    changed()
  end
end

return M
