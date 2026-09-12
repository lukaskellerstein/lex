-- lex.conv: a conversation, which is what the reader counts and lists.
--
-- The store is a record per place per prompt, because that is what a writer
-- can know in the moment. What a person has, though, is a conversation: one
-- session with one agent, which they hand places to over time. Two places
-- in the first prompt and a third one ten minutes later, from another file,
-- are one conversation with three places, not three things (Lukas,
-- 2026-09-12: "one session ID, one coding agent, with multiple selections").
--
-- So everything the reader shows groups the records by `session`:
--
--   the badge `💬 N`      N conversations touch this range
--   the explorer count    N conversations touch this file or folder
--   a picker row          one conversation, however many places it has
--   the preview           every place of that conversation, and its prompts
--
-- A record is never lost by the grouping: `recs` keeps them all, oldest
-- first, and `places` is the distinct places in the order they were added.
--
-- Rex calls this a comment and Lex calls it a conversation, for the same
-- reason the two products differ: a Rex comment can be answered by several
-- agents, and a Lex conversation is one session of one agent.

local links = require("lex.links")

local M = {}

---@class lex.Place2
---@field file? string
---@field dir? string
---@field from? integer
---@field to? integer
---@field rec lex.Record   the newest record of this place
---@field key string

---@class lex.Conv
---@field session string
---@field agent string
---@field repo string
---@field recs lex.Record[]     every record, oldest first
---@field places lex.Place2[]   distinct places, in the order they were added
---@field newest lex.Record
---@field at integer            the newest record's time
---@field started integer       the oldest record's time
---@field prompts string[]      the prompts, oldest first, without repeats

--- The key that says "the same place": a folder, a whole file, or a range.
---@param rec lex.Record
---@return string
function M.key(rec)
  if rec.dir then
    return "dir:" .. rec.dir
  end
  if not rec.from then
    return "file:" .. tostring(rec.file)
  end
  return ("range:%s:%d-%d"):format(tostring(rec.file), rec.from, rec.to)
end

--- Group records into conversations, the most recent first.
---@param records lex.Record[]
---@return lex.Conv[]
function M.group(records)
  local by, order = {}, {}
  for _, rec in ipairs(records) do
    local id = rec.session or "?"
    local c = by[id]
    if not c then
      c = { session = id, agent = rec.agent, repo = rec.repo, recs = {}, places = {}, prompts = {}, at = 0, started = math.huge }
      by[id] = c
      order[#order + 1] = c
    end
    c.recs[#c.recs + 1] = rec
  end
  for _, c in ipairs(order) do
    table.sort(c.recs, function(a, b)
      if (a.at or 0) ~= (b.at or 0) then
        return (a.at or 0) < (b.at or 0)
      end
      return (a.index or 0) < (b.index or 0)
    end)
    local seen_place, seen_prompt = {}, {}
    for _, rec in ipairs(c.recs) do
      local k = M.key(rec)
      if seen_place[k] then
        seen_place[k].rec = rec
      else
        local p = { file = rec.file, dir = rec.dir, from = rec.from, to = rec.to, rec = rec, key = k }
        seen_place[k] = p
        c.places[#c.places + 1] = p
      end
      local prompt = rec.prompt or ""
      if prompt ~= "" and not seen_prompt[prompt] then
        seen_prompt[prompt] = true
        c.prompts[#c.prompts + 1] = prompt
      end
    end
    c.newest = c.recs[#c.recs]
    c.at = c.newest.at or 0
    c.started = c.recs[1].at or c.at
  end
  table.sort(order, function(a, b)
    return a.at > b.at
  end)
  return order
end

--- Every conversation of a repository, most recent first.
---@param repo string
---@return lex.Conv[]
function M.all(repo)
  return M.group(links.repo(repo).records)
end

--- One conversation, with every place it has in the repository.
---@param repo string
---@param session string
---@return lex.Conv|nil
function M.of(repo, session)
  local mine = {}
  for _, rec in ipairs(links.repo(repo).records) do
    if rec.session == session then
      mine[#mine + 1] = rec
    end
  end
  if #mine == 0 then
    return nil
  end
  return M.group(mine)[1]
end

--- How many distinct conversations are in a list of records.
---@param records lex.Record[]
---@return integer
function M.count(records)
  local seen, n = {}, 0
  for _, rec in ipairs(records) do
    local id = rec.session or "?"
    if not seen[id] then
      seen[id] = true
      n = n + 1
    end
  end
  return n
end

---@class lex.Turn
---@field prompt string
---@field at integer
---@field recs lex.Record[]   the places that came with this prompt
---@field n integer           its number, 1 for the first

--- The turns of a conversation, oldest first: one prompt and the places it
--- carried. A writer records a place per place per prompt and stamps them
--- with one time, so a turn is the records that share a time and a prompt.
--- Only the turns that carried a place are here; Lex never sees the others.
---@param c lex.Conv
---@return lex.Turn[]
function M.turns(c)
  local turns, by = {}, {}
  for _, rec in ipairs(c.recs) do
    local key = ("%d|%s"):format(rec.at or 0, rec.prompt or "")
    local t = by[key]
    if not t then
      t = { prompt = rec.prompt or "", at = rec.at or 0, recs = {} }
      by[key] = t
      turns[#turns + 1] = t
    end
    t.recs[#t.recs + 1] = rec
  end
  for i, t in ipairs(turns) do
    t.n = i
    table.sort(t.recs, function(a, b)
      return (a.index or 0) < (b.index or 0)
    end)
  end
  return turns
end

local repo_count = {}

--- How many conversations a repository holds, not counting the ones whose
--- transcript is gone. Cached until the store file changes, because the
--- statusline asks on every redraw: the answer is recomputed only when the
--- bytes read or the number of records moved.
---@param repo string
---@return integer
function M.count_repo(repo)
  local r = links.repo(repo)
  local c = repo_count[repo]
  if c and c.offset == r.offset and c.records == #r.records then
    return c.count
  end
  -- `gone` is a file check, so ask it once per conversation, not per record.
  local newest = {}
  for _, rec in ipairs(r.records) do
    local id = rec.session or "?"
    local have = newest[id]
    if not have or (rec.at or 0) >= (have.at or 0) then
      newest[id] = rec
    end
  end
  local n = 0
  for _, rec in pairs(newest) do
    if not links.gone(rec) then
      n = n + 1
    end
  end
  repo_count[repo] = { offset = r.offset, records = #r.records, count = n }
  return n
end

--- Is the conversation's agent working on an answer right now?
---@param c lex.Conv
---@return boolean
function M.working(c)
  return links.running(c.newest)
end

--- Is its transcript gone?
---@param c lex.Conv
---@return boolean
function M.gone(c)
  return links.gone(c.newest)
end

--- How many files and folders a conversation touches.
---@param c lex.Conv
---@return integer
function M.files(c)
  local seen, n = {}, 0
  for _, p in ipairs(c.places) do
    local k = p.dir and ("dir:" .. p.dir) or ("file:" .. tostring(p.file))
    if not seen[k] then
      seen[k] = true
      n = n + 1
    end
  end
  return n
end

return M
