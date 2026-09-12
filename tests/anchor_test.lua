-- Tests for lex.anchor. Run: nvim -l tests/anchor_test.lua
--
-- The case table from PLAN.md § The nvim side, 1: what the resolver says for
-- each kind of change to a file after a record was written.

vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(_G.arg[0], ":p")))))

local anchor = require("lex.anchor")
local checks, failed = 0, 0

local function eq(got, want, what)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

--- A fresh 60-line file: distinct lines, so nothing matches by accident.
local function file()
  local t = {}
  for i = 1, 60 do
    t[i] = ("  local v%d = f(%d)"):format(i, i)
  end
  return t
end

--- A record for lines from..to of `lines`, the way the hook writes it.
local function record(lines, from, to)
  local body = table.concat(lines, "\n", from, to)
  local rec = { from = from, to = to, body = body, hash = anchor.fnv1a(body) }
  rec.head = vim.trim(lines[from])
  rec.tail = vim.trim(lines[to])
  if from > 1 then
    rec.before = table.concat(lines, "\n", math.max(1, from - 2), from - 1)
  end
  if to < #lines then
    rec.after = table.concat(lines, "\n", to + 1, math.min(#lines, to + 2))
  end
  return rec
end

local function resolve(rec, lines)
  return anchor.resolve(rec, anchor.index(lines))
end

local function insert(lines, at, n, text)
  for _ = 1, n do
    table.insert(lines, at, text or "  -- inserted")
  end
end

local base = file()
local rec = record(base, 10, 13)

-- unchanged
eq(resolve(rec, file()), { state = "ok", from = 10, to = 13, layer = 1 }, "unchanged: ok")

-- lines added above
local L = file()
insert(L, 3, 5)
eq(resolve(rec, L), { state = "moved", from = 15, to = 18, layer = 2 }, "added above: moved, exact")

-- a re-indent is not a change
L = file()
for i = 10, 13 do
  L[i] = "      " .. vim.trim(L[i])
end
eq(resolve(rec, L), { state = "ok", from = 10, to = 13, layer = 1 }, "re-indented: ok")

-- a line added in the middle
L = file()
insert(L, 12, 1)
eq(resolve(rec, L), { state = "moved", edited = true, from = 10, to = 14, layer = 3 }, "added inside: moved, edited, the range grew")

-- a line removed from the middle
L = file()
table.remove(L, 12)
eq(resolve(rec, L), { state = "moved", edited = true, from = 10, to = 12, layer = 3 }, "removed inside: moved, edited, the range shrank")

-- a line in the middle rewritten
L = file()
L[12] = "  local v12 = g(12) -- changed"
eq(resolve(rec, L), { state = "moved", edited = true, from = 10, to = 13, layer = 3 }, "rewritten inside: moved, edited")

-- the first line rewritten (a renamed function)
L = file()
L[10] = "  local renamed = f(10)"
eq(resolve(rec, L), { state = "moved", edited = true, from = 10, to = 13, layer = 3 }, "first line rewritten: still found, the mark covers it")

-- the last line rewritten
L = file()
L[13] = "  local renamed = f(13)"
eq(resolve(rec, L), { state = "moved", edited = true, from = 10, to = 13, layer = 3 }, "last line rewritten: still found")

-- both edges rewritten: 2 of 4 is under three quarters
L = file()
L[10] = "  local a = 1"
L[13] = "  local b = 2"
eq(resolve(rec, L).state, "orphaned", "both edges of a 4-line range rewritten: orphaned")

-- both edges rewritten on an 8-line range: 6 of 8 is enough
local rec8 = record(base, 30, 37)
L = file()
L[30] = "  local a = 1"
L[37] = "  local b = 2"
eq(resolve(rec8, L), { state = "moved", edited = true, from = 30, to = 37, layer = 3 }, "both edges of an 8-line range rewritten: found")

-- more than a quarter rewritten
L = file()
L[10], L[11], L[12] = "  x", "  y", "  z"
eq(resolve(rec, L).state, "orphaned", "3 of 4 lines rewritten: orphaned")

-- shifted and edited at once
L = file()
insert(L, 3, 5)
L[17] = "  local v12 = g(12) -- changed"
eq(resolve(rec, L), { state = "moved", edited = true, from = 15, to = 18, layer = 3 }, "shifted and edited: found at the new place")

-- the whole file rewritten
L = {}
for i = 1, 40 do
  L[i] = ("  other%d()"):format(i)
end
eq(resolve(rec, L), { state = "orphaned", layer = 4 }, "everything rewritten: orphaned")

-- an empty file
eq(resolve(rec, {}).state, "orphaned", "empty file: orphaned")

-- the same lines three times: context picks the copy
L = file()
local dup = { "  if a then", "    retry()", "  end" }
for _, at in ipairs({ 40, 45, 50 }) do
  L[at - 1] = ("  -- copy %d"):format(at)
  for k = 1, 3 do
    L[at + k - 1] = dup[k]
  end
end
local rec_dup = record(L, 45, 47)
insert(L, 3, 5)
-- after the shift the first copy sits exactly where the record points
eq(resolve(rec_dup, L), { state = "moved", from = 50, to = 52, layer = 2 }, "duplicates: before/after pick the second copy, not the identical one at the old place")
local no_ctx = vim.deepcopy(rec_dup)
no_ctx.before, no_ctx.after = nil, nil
eq(resolve(no_ctx, L), { state = "ok", from = 45, to = 47, layer = 1 }, "duplicates without context: the old place, which is the nearest")
no_ctx.from, no_ctx.to = 46, 48
eq(resolve(no_ctx, L), { state = "moved", from = 45, to = 47, layer = 2 }, "duplicates without context, old place off by one: the nearest copy")

-- a one-line range: exact or nothing
local rec1 = record(base, 20, 20)
L = file()
insert(L, 3, 5)
eq(resolve(rec1, L), { state = "moved", from = 25, to = 25, layer = 2 }, "one line, shifted: moved")
L = file()
L[20] = "  local v20 = g(20)"
eq(resolve(rec1, L).state, "orphaned", "one line, rewritten: orphaned, no fuzzy for one line")

-- weak lines never claim a link
L = {}
for i = 1, 30 do
  L[i] = "}"
end
local braces = { from = 5, to = 8, body = "}\n}\nx = 1\n}" }
eq(resolve(braces, L).state, "orphaned", "braces only: no false positive")
L[7] = "x = 1"
eq(resolve(braces, L), { state = "ok", from = 5, to = 8, layer = 1 }, "braces with the strong line in place: ok")

-- blank lines inside the body do not count
L = file()
L[10], L[11], L[12] = "  a = 1", "", "  b = 2"
local rec_blank = { from = 10, to = 12, body = "  a = 1\n\n  b = 2" }
eq(resolve(rec_blank, L), { state = "ok", from = 10, to = 12, layer = 1 }, "blank inside, unchanged: ok")
table.insert(L, 11, "")
eq(resolve(rec_blank, L), { state = "moved", edited = true, from = 10, to = 13, layer = 3 }, "blank inside, one more blank: found")

-- a whole-file or folder record never moves
eq(resolve({ file = "x.ts" }, file()), { state = "ok" }, "whole file: ok")
eq(resolve({ dir = "src" }, file()), { state = "ok" }, "folder: ok")

-- records written without a body: head, tail and hash only
local keys = { from = 10, to = 13, head = rec.head, tail = rec.tail, hash = rec.hash }
eq(resolve(keys, file()), { state = "ok", from = 10, to = 13, layer = 1 }, "keys: unchanged")
L = file()
insert(L, 3, 5)
eq(resolve(keys, L), { state = "moved", from = 15, to = 18, layer = 2 }, "keys: shifted")
L = file()
L[12] = "  changed"
eq(resolve(keys, L), { state = "moved", edited = true, from = 10, to = 13, layer = 3 }, "keys: edited inside, head and tail in order")
L = file()
L[10] = "  changed"
eq(resolve(keys, L).state, "orphaned", "keys: head rewritten is orphaned; that is why the body is stored now")
eq(resolve({ from = 1, to = 2 }, file()).state, "orphaned", "keys: nothing to go on")

-- the hash the writers use
eq(anchor.fnv1a("a"), "e40c292c", "fnv1a: a")
eq(anchor.fnv1a("foo bar"), "bf9cf968", "fnv1a: whitespace removed")

-- cost: 50 links in a 5,200-line file, every one shifted
local big = {}
for i = 1, 5000 do
  big[i] = ("  local value_%d = compute(%d)"):format(i, i)
end
local recs = {}
for k = 1, 50 do
  recs[k] = record(big, k * 90, k * 90 + 3)
end
insert(big, 10, 200)
local t0 = vim.uv.hrtime()
local idx = anchor.index(big)
local states = {}
for _, r in ipairs(recs) do
  local s = anchor.resolve(r, idx).state
  states[s] = (states[s] or 0) + 1
end
local ms = (vim.uv.hrtime() - t0) / 1e6
eq(states, { moved = 50 }, "50 links shifted by 200 lines: all found")
io.stdout:write(("  50 links in 5,200 lines, index and resolve: %.1f ms\n"):format(ms))

io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
