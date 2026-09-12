-- lex.marks: the links, painted in the buffer. PLAN.md § The look is the
-- rule book; prototype/marks.lua is the same paint on fake data.
--
-- Three layers, three namespaces:
--
--   static   a wash and a sign bar on every row of a range; tone 2 and `▎▎`
--            where ranges overlap; a whole-file or folder place adds a lane
--            on every row and no wash. Repainted when the buffer's text or
--            the store changed.
--   badge    `💬 N` at the end of a range's first row; the newest prompt and
--            its age while the cursor stands inside; `working…` while the
--            session's process lives. Repainted on every cursor move: one
--            extmark per range, cheap.
--   pending  copied, not yet sent: rows blue, the sign `┆` (or `▎┆` over
--            history), a hollow `📌 n`. Its wash wins over history.
--
-- The lines move, the store does not: every repaint resolves each record
-- against the buffer as it is now (lex.anchor), so a mark follows an edit,
-- an agent's edit that `autoread` pulled in, and a reload from disk alike.
-- Text changes repaint after a 300 ms pause. 2 ms for 50 links.

local anchor = require("lex.anchor")
local conv = require("lex.conv")
local links = require("lex.links")
local pending = require("lex.pending")
local place = require("lex.place")

local M = {}

local ns_static = vim.api.nvim_create_namespace("lex_static")
local ns_badge = vim.api.nvim_create_namespace("lex_badge")
local group = vim.api.nvim_create_augroup("lex_marks", { clear = true })

---@class lex.Range
---@field from integer
---@field to integer
---@field recs lex.Record[]
---@field working boolean
---@field edited boolean

---@class lex.BufState
---@field repo string
---@field file string
---@field links { rec: lex.Record, res: lex.Resolution, gone: boolean }[]
---@field ranges lex.Range[]
---@field whole lex.Record[]
---@field folder lex.Record[]
---@field pending lex.Pending[]
---@field count integer          conversations that still have a place here: not gone, not orphaned

---@type table<integer, lex.BufState>
local state = {}

local function config()
  return require("lex").config
end

--- `0` means the current buffer everywhere in the API; the state table is
--- keyed by the real number.
local function real_buf(buf)
  if buf == 0 or buf == nil then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

--- The repository and the relative file of a buffer, or nothing for a
--- buffer that is not a file on disk.
---@param buf integer
---@return string|nil repo, string|nil file
function M.file_of(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not vim.uv.fs_stat(name) then
    return nil
  end
  local path = vim.uv.fs_realpath(name) or name
  local repo, root = links.roots(path)
  return repo, place.relative(path, root)
end

--- Resolve every record for the buffer and group the ranges.
---@param buf integer
---@return lex.BufState|nil
local function compute(buf)
  local repo, file = M.file_of(buf)
  if not repo then
    return nil
  end
  local idx = anchor.index(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local st = { repo = repo, file = file, links = {}, ranges = {}, whole = {}, folder = {}, pending = {}, count = 0 }
  local by_range, live = {}, {}
  for _, rec in ipairs(links.for_file(repo, file)) do
    local gone = links.gone(rec)
    local res = anchor.resolve(rec, idx)
    st.links[#st.links + 1] = { rec = rec, res = res, gone = gone }
    if not gone and res.state ~= "orphaned" then
      live[#live + 1] = rec
      if rec.dir then
        st.folder[#st.folder + 1] = rec
      elseif not rec.from then
        st.whole[#st.whole + 1] = rec
      else
        local key = res.from .. "-" .. res.to
        local r = by_range[key]
        if not r then
          r = { from = res.from, to = res.to, recs = {}, working = false, edited = false }
          by_range[key] = r
          st.ranges[#st.ranges + 1] = r
        end
        r.recs[#r.recs + 1] = rec
        r.working = r.working or links.running(rec)
        r.edited = r.edited or res.edited or false
      end
    end
  end
  -- The counts are conversations, not records: two places sent in one
  -- prompt are one conversation, and so is a third one added an hour later
  -- (lex.conv).
  st.count = conv.count(live)
  for _, r in ipairs(st.ranges) do
    table.sort(r.recs, function(a, b)
      return (a.at or 0) > (b.at or 0)
    end)
    r.convs = conv.count(r.recs)
  end
  table.sort(st.ranges, function(a, b)
    return a.from < b.from
  end)
  st.pending = pending.for_file(repo, file)
  return st
end

--- The static layer.
---@param buf integer
---@param st lex.BufState
local function paint_static(buf, st)
  vim.api.nvim_buf_clear_namespace(buf, ns_static, 0, -1)
  local cfg = config()
  local total = vim.api.nvim_buf_line_count(buf)
  local cover = {}
  for _, r in ipairs(st.ranges) do
    for row = r.from, math.min(r.to, total) do
      cover[row] = (cover[row] or 0) + 1
    end
  end
  local lane = (#st.whole > 0 or #st.folder > 0) and 1 or 0
  local pend = {}
  local pend_all = false
  for _, e in ipairs(st.pending) do
    if e.from then
      for row = e.from, math.min(e.to, total) do
        pend[row] = true
      end
    else
      pend_all = true
    end
  end
  for row = 1, total do
    local n = cover[row] or 0
    local lanes = n + lane
    local p = pend_all or pend[row]
    if lanes > 0 or p then
      local wash
      if cfg.wash then
        wash = p and "LexPendingWash" or (n > 0 and ("LexWash" .. math.min(n, 3))) or nil
      end
      vim.api.nvim_buf_set_extmark(buf, ns_static, row - 1, 0, {
        line_hl_group = wash,
        sign_text = p and (lanes > 0 and "▎┆" or "┆") or (lanes >= 2 and "▎▎" or "▎"),
        sign_hl_group = p and "LexPendingSign" or "LexSign",
        priority = 5,
        strict = false,
      })
    end
  end
end

--- The badge layer.
---@param buf integer
---@param st lex.BufState
local function paint_badges(buf, st)
  vim.api.nvim_buf_clear_namespace(buf, ns_badge, 0, -1)
  local cfg = config()
  local total = vim.api.nvim_buf_line_count(buf)
  local win = vim.fn.bufwinid(buf)
  local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 0
  local function badge(row, n, text, working, prio)
    local chunks = { { " " .. cfg.icon .. " " .. n .. " ", "LexBadge" } }
    if text then
      chunks[#chunks + 1] = { " " .. text .. " ", "LexBadgeText" }
    end
    if working then
      chunks[#chunks + 1] = { " working… ", "LexWorking" }
    end
    vim.api.nvim_buf_set_extmark(buf, ns_badge, row - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "eol_right_align",
      priority = prio or 20,
      strict = false,
    })
  end
  for _, r in ipairs(st.ranges) do
    if r.from <= total then
      local text
      if cur >= r.from and cur <= r.to then
        local newest = r.recs[1]
        text = (newest.prompt ~= "" and newest.prompt or "(no question)") .. "  ·  " .. links.age(newest.at)
      end
      badge(r.from, r.convs, text, r.working)
    end
  end
  if #st.whole > 0 or #st.folder > 0 then
    local parts, working = {}, false
    if #st.whole > 0 then
      parts[#parts + 1] = "whole file"
    end
    local seen = {}
    for _, rec in ipairs(st.folder) do
      if not seen[rec.dir] then
        seen[rec.dir] = true
        parts[#parts + 1] = "folder " .. (rec.dir == "." and "/" or rec.dir .. "/")
      end
    end
    for _, rec in ipairs(st.whole) do
      working = working or links.running(rec)
    end
    for _, rec in ipairs(st.folder) do
      working = working or links.running(rec)
    end
    local both = vim.list_extend(vim.list_slice(st.whole), st.folder)
    badge(1, conv.count(both), table.concat(parts, " · "), working)
  end
  for _, e in ipairs(st.pending) do
    local row = e.from or 1
    if row <= total then
      local chunks = { { " " .. cfg.pin .. " " .. e.n .. " ", "LexPendingBadge" } }
      if not e.from then
        chunks[#chunks + 1] = { e.dir and (" folder " .. (e.dir == "." and "/" or e.dir .. "/") .. " ") or " whole file ", "LexPendingBadge" }
      end
      vim.api.nvim_buf_set_extmark(buf, ns_badge, row - 1, 0, {
        virt_text = chunks,
        virt_text_pos = "eol_right_align",
        priority = 21,
        strict = false,
      })
    end
  end
end

--- Resolve and paint a buffer. The whole thing; call it when the text or the
--- store changed.
---@param buf integer
function M.refresh(buf)
  buf = real_buf(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    state[buf] = nil
    return
  end
  local st = compute(buf)
  if not st then
    if state[buf] then
      vim.api.nvim_buf_clear_namespace(buf, ns_static, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, ns_badge, 0, -1)
    end
    state[buf] = nil
    return
  end
  state[buf] = st
  paint_static(buf, st)
  paint_badges(buf, st)
end

--- Only the badge layer, on a cursor move.
---@param buf integer
function M.badges(buf)
  buf = real_buf(buf)
  local st = state[buf]
  if st then
    paint_badges(buf, st)
  end
end

--- What is known about a buffer, or nil.
---@param buf integer
---@return lex.BufState|nil
function M.state(buf)
  return state[real_buf(buf)]
end

--- The records with a place on a row: the ranges that contain it, then the
--- whole-file and folder places, which are on every row. Newest first.
---@param buf integer
---@param row integer
---@return lex.Record[]
function M.records_at(buf, row)
  local st = state[real_buf(buf)]
  if not st then
    return {}
  end
  local out = {}
  for _, r in ipairs(st.ranges) do
    if row >= r.from and row <= r.to then
      vim.list_extend(out, r.recs)
    end
  end
  vim.list_extend(out, st.whole)
  vim.list_extend(out, st.folder)
  return out
end

--- How many conversations touch a row.
---@param buf integer
---@param row integer
---@return integer
function M.count_at(buf, row)
  return conv.count(M.records_at(buf, row))
end

local generation = {} ---@type table<integer, integer>

--- Repaint after a pause in typing.
---@param buf integer
local function refresh_soon(buf)
  local gen = (generation[buf] or 0) + 1
  generation[buf] = gen
  vim.defer_fn(function()
    if generation[buf] == gen then
      M.refresh(buf)
    end
  end, 300)
end

--- Watch a buffer.
---@param buf integer
function M.attach(buf)
  buf = real_buf(buf)
  if vim.b[buf].lex_attached then
    return
  end
  vim.b[buf].lex_attached = true
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.badges(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      refresh_soon(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "BufReadPost" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      state[buf] = nil
      generation[buf] = nil
    end,
  })
  M.refresh(buf)
end

--- Every attached buffer again: the store changed, the wash was toggled.
---@param repo? string only the buffers of this repository
function M.refresh_all(repo)
  for buf, st in pairs(state) do
    if not repo or st.repo == repo then
      M.refresh(buf)
    end
  end
end

--- Wash on or off, everywhere.
function M.toggle_wash()
  local cfg = config()
  cfg.wash = not cfg.wash
  M.refresh_all()
  vim.notify("Lex wash " .. (cfg.wash and "on" or "off"), vim.log.levels.INFO)
end

--- Autocmds for every buffer. Called once from setup().
function M.setup()
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if M.file_of(ev.buf) then
        M.attach(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      links.refresh_all()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LexStoreChanged",
    callback = function(ev)
      local repo = ev.data and ev.data.repo
      if repo then
        pending.on_store(repo)
      end
      M.refresh_all(repo)
      vim.cmd.redrawstatus()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LexPendingChanged",
    callback = function()
      M.refresh_all()
    end,
  })
  -- A session started or stopped working: the `working…` badges follow.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LexSessionChanged",
    callback = function()
      for buf, st in pairs(state) do
        if vim.api.nvim_buf_is_loaded(buf) then
          for _, r in ipairs(st.ranges) do
            r.working = false
            for _, rec in ipairs(r.recs) do
              r.working = r.working or links.running(rec)
            end
          end
          paint_badges(buf, st)
        end
      end
    end,
  })
  links.watch_sessions()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.file_of(buf) then
      M.attach(buf)
    end
  end
end

return M
