-- lex.anchor: find the lines a record talks about in the file as it is now.
--
-- The store holds where the text was. This finds where it is. A record's
-- `from`/`to` are a hint, never the answer; the answer comes from the text
-- itself, in layers, the first that succeeds wins (Rex, `resolve.ts`):
--
--   1  the body, line for line, at `from`                       ok
--   2  the body, line for line, elsewhere; when the same lines
--      appear more than once, `before`/`after` pick the copy,
--      then the nearest to `from`                                moved
--   3  fuzzy: the window where at least three quarters of the
--      body's strong lines appear in order                       moved, edited
--   4  nothing                                                   orphaned
--
-- A strong line is one that can prove anything: longer than three characters
-- and not only punctuation. `}`, `end`, `);` and blank lines neither start a
-- search nor count toward the three quarters, so a file full of braces never
-- claims a link it does not own. Layer 3 needs two strong lines; a one-line
-- range is exact or orphaned, which is right.
--
-- Lines are compared trimmed, so a re-indent is not a change. No positional
-- fallback: a mark never sits on lines that do not say what the conversation
-- saw. `orphaned` is a normal state, listed in the picker, greyed.
--
-- A record written without a body (only `head`, `tail`, `hash`) resolves by
-- those keys: the same three layers with less to go on.
--
-- Pure: `index()` takes the buffer's lines, `resolve()` takes a record and
-- that index. Nothing here touches nvim, so it is tested with plain tables.

local M = {}

--- Lines each side that a record carries.
M.CONTEXT = 2
--- Share of the strong lines layer 3 must find, in order.
M.FUZZY = 0.75
--- How far a fuzzy window may stretch, as a multiple of the body's length.
M.WINDOW = 1.5

---@class lex.Resolution
---@field state "ok"|"moved"|"orphaned"
---@field from? integer     first line now, 1-based
---@field to? integer       last line now
---@field edited? boolean   the text inside changed (layer 3)
---@field layer? 1|2|3|4

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(s)
  local t = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    t[#t + 1] = line
  end
  return t
end

--- Too common to prove anything.
local function weak(t)
  return #t <= 3 or t:match("^[%p%s]*$") ~= nil
end

--- FNV-1a, 32 bits, over the text with every whitespace character removed.
--- The writers' hash, for records that carry no body.
---@param body string
---@return string
function M.fnv1a(body)
  local s = body:gsub("[ \t\n\v\f\r]+", "")
  local h = 2166136261
  for i = 1, #s do
    local lo, b, x, m = h % 256, s:byte(i), 0, 1
    for _ = 1, 8 do
      local a, c = lo % 2, b % 2
      if a ~= c then
        x = x + m
      end
      lo, b, m = (lo - a) / 2, (b - c) / 2, m * 2
    end
    h = h - h % 256 + x
    h = ((h % 256) * 16777216 + h * 403) % 4294967296
  end
  return ("%08x"):format(h)
end

---@class lex.Index
---@field lines string[]                raw
---@field trimmed string[]
---@field at table<string, integer[]>   trimmed text → the lines that say it
---@field n integer

--- The buffer as the resolver wants it. Build once per buffer, resolve many.
---@param lines string[]
---@return lex.Index
function M.index(lines)
  local trimmed, at = {}, {}
  for i, l in ipairs(lines) do
    local t = trim(l)
    trimmed[i] = t
    local list = at[t]
    if not list then
      list = {}
      at[t] = list
    end
    list[#list + 1] = i
  end
  return { lines = lines, trimmed = trimmed, at = at, n = #lines }
end

local function nearest(hits, from)
  local best
  for _, s in ipairs(hits) do
    if not best or math.abs(s - from) < math.abs(best - from) then
      best = s
    end
  end
  return best
end

--- Among exact hits, the one whose surroundings match `before`/`after` best;
--- a tie goes to the nearest to `from`.
local function pick(hits, rec, idx, n)
  local before, after = {}, {}
  if rec.before then
    before = split(rec.before)
  end
  if rec.after then
    after = split(rec.after)
  end
  if #before == 0 and #after == 0 then
    return nearest(hits, rec.from)
  end
  local best, best_score = nil, -1
  for _, s in ipairs(hits) do
    local score = 0
    for k = 1, #before do
      local line = idx.trimmed[s - k]
      if line and line == trim(before[#before - k + 1]) then
        score = score + 1
      end
    end
    for k = 1, #after do
      local line = idx.trimmed[s + n - 1 + k]
      if line and line == trim(after[k]) then
        score = score + 1
      end
    end
    if score > best_score or (score == best_score and math.abs(s - rec.from) < math.abs(best - rec.from)) then
      best, best_score = s, score
    end
  end
  return best
end

--- Records without a body: `head`, `tail` and `hash` only.
local function by_keys(rec, idx)
  if not rec.head then
    return { state = "orphaned", layer = 4 }
  end
  local len = (rec.to or rec.from) - rec.from
  local tail = rec.tail or rec.head
  local function same(at)
    if at < 1 or at + len > idx.n then
      return false
    end
    if idx.trimmed[at] ~= rec.head or idx.trimmed[at + len] ~= tail then
      return false
    end
    return not rec.hash or M.fnv1a(table.concat(idx.lines, "\n", at, at + len)) == rec.hash
  end
  if same(rec.from) then
    return { state = "ok", from = rec.from, to = rec.from + len, layer = 1 }
  end
  local hits = {}
  for _, i in ipairs(idx.at[rec.head] or {}) do
    if same(i) then
      hits[#hits + 1] = i
    end
  end
  if #hits > 0 then
    local s = nearest(hits, rec.from)
    return { state = "moved", from = s, to = s + len, layer = 2 }
  end
  -- head and tail in order, the hash different: edited inside
  if rec.tail and not weak(rec.head) then
    local span = math.floor((len + 1) * M.WINDOW) + 2
    local cands = {}
    for _, i in ipairs(idx.at[rec.head] or {}) do
      for k = i + 1, math.min(idx.n, i + span) do
        if idx.trimmed[k] == tail then
          cands[#cands + 1] = { i, k }
          break
        end
      end
    end
    if #cands > 0 then
      local best
      for _, c in ipairs(cands) do
        if not best or math.abs(c[1] - rec.from) < math.abs(best[1] - rec.from) then
          best = c
        end
      end
      return { state = "moved", edited = true, from = best[1], to = best[2], layer = 3 }
    end
  end
  return { state = "orphaned", layer = 4 }
end

--- Where a record's lines are now.
---@param rec lex.Record
---@param idx lex.Index
---@return lex.Resolution
function M.resolve(rec, idx)
  if not rec.from then
    return { state = "ok" }
  end
  if rec.body == nil then
    return by_keys(rec, idx)
  end

  local B = split(rec.body)
  for j, l in ipairs(B) do
    B[j] = trim(l)
  end
  local n = #B

  local function exact(at)
    if at < 1 or at + n - 1 > idx.n then
      return false
    end
    for j = 1, n do
      if idx.trimmed[at + j - 1] ~= B[j] then
        return false
      end
    end
    return true
  end

  -- 1 and 2. every place the body appears, line for line. The old place is
  -- not trusted on its own: when the same lines appear twice, an identical
  -- copy can sit exactly where the record points, and only `before`/`after`
  -- tell the copies apart. The probe is the first strong line.
  local probe, pj
  for j = 1, n do
    if not weak(B[j]) then
      probe, pj = B[j], j
      break
    end
  end
  if not probe then
    for j = 1, n do
      if B[j] ~= "" then
        probe, pj = B[j], j
        break
      end
    end
  end
  local hits = {}
  if probe then
    for _, i in ipairs(idx.at[probe] or {}) do
      local s = i - (pj - 1)
      if exact(s) then
        hits[#hits + 1] = s
      end
    end
  elseif exact(rec.from) then
    hits[1] = rec.from
  end
  if #hits > 0 then
    local s = #hits == 1 and hits[1] or pick(hits, rec, idx, n)
    if s == rec.from then
      return { state = "ok", from = s, to = s + n - 1, layer = 1 }
    end
    return { state = "moved", from = s, to = s + n - 1, layer = 2 }
  end

  -- 3. fuzzy: the window where most strong lines appear in order
  local strong = {}
  for j = 1, n do
    if not weak(B[j]) then
      strong[#strong + 1] = j
    end
  end
  local m = #strong
  if m >= 2 then
    local need = math.ceil(M.FUZZY * m)
    local span = math.floor(n * M.WINDOW) + 2
    local starts, seen = {}, {}
    for _, j in ipairs(strong) do
      local occ = idx.at[B[j]]
      if occ and #occ <= 200 then
        for _, i in ipairs(occ) do
          local s = i - (j - 1)
          if not seen[s] then
            seen[s] = true
            starts[#starts + 1] = s
          end
        end
      end
    end
    local best, best_score, best_first, best_last, best_fj, best_lj
    for _, s in ipairs(starts) do
      local lo, hi = math.max(1, s), math.min(idx.n, s + span)
      local pos, matched, first, last, fj, lj = lo, 0, nil, nil, nil, nil
      for _, j in ipairs(strong) do
        local i = pos
        while i <= hi and idx.trimmed[i] ~= B[j] do
          i = i + 1
        end
        if i <= hi then
          matched = matched + 1
          if not first then
            first, fj = i, j
          end
          last, lj = i, j
          pos = i + 1
        end
      end
      if matched >= need and (not best or matched > best_score or (matched == best_score and math.abs(s - rec.from) < math.abs(best - rec.from))) then
        best, best_score, best_first, best_last, best_fj, best_lj = s, matched, first, last, fj, lj
      end
    end
    if best then
      -- stretch over the body's unmatched edge lines, which are still there,
      -- rewritten
      local from = math.max(1, best_first - (best_fj - 1))
      local to = math.min(idx.n, best_last + (n - best_lj))
      return { state = "moved", edited = true, from = from, to = to, layer = 3 }
    end
  end

  return { state = "orphaned", layer = 4 }
end

return M
