-- The Lex writer for Claude Code and Codex. Runs on every prompt, and once
-- more when the answer ends:
--
--   nvim -l hook.lua                 as a Claude Code UserPromptSubmit and Stop hook
--   nvim -l hook.lua --agent codex   the same for Codex
--
-- stdin is the hook's JSON: `hook_event_name`, `session_id`, `cwd`,
-- `prompt`, `transcript_path` and the rest. Two jobs:
--
--   * On every event, the session's state file is written, one per session:
--
--       $LEX_HOME/sessions/<session>.json    {"state":…,"pid":…,"pane":…}
--
--     `idle` on SessionStart (a start, a resume, a clear; not a compaction),
--     `working` on UserPromptSubmit, `idle` on Stop, `ended` on SessionEnd.
--     The editor reads `working` as `working…`, and takes the pid and the
--     pane from here rather than from a record: a session resumed in a new
--     process has a new pid, and the record only knows the old one (seen
--     2026-09-12). A process id alone cannot say working either: an idle
--     agent waiting for the next prompt is a living process.
--
--   * On UserPromptSubmit, the prompt is scanned for `<lex-place …>…</lex-place>`
--     and `<lex-place …/>` blocks; one record per block is appended to
--
--       $LEX_HOME/<repo-slug>/links.jsonl      ($LEX_HOME defaults to ~/.lex)
--
--     where <repo-slug> is the block's `repo` with every character that is
--     not a letter or a digit turned into `-`, the rule Claude Code uses for
--     ~/.claude/projects/. One file per repository keeps the editor's reads
--     small.
--
-- Rules that keep this file honest:
--
--   * It never fails the prompt. Every path ends in `os.exit(0)`: garbage on
--     stdin, a missing field, a full disk. An error is appended to
--     $LEX_HOME/hook.log and nothing else happens.
--   * It never prints to stdout. For UserPromptSubmit, stdout becomes context
--     for the model.
--   * It runs no git and no network. It is on every prompt of every session;
--     the budget is under 50 ms, and `nvim -l` starts in under 10.
--   * It is self-contained: no `require` of lex.nvim, because the published
--     Claude Code plugin is this folder alone. The parser here is a copy of
--     `lua/lex/place.lua` in lex.nvim, and `contract/` in the same repository
--     keeps every writer equal to it: the same prompt must give the same
--     records, byte for byte where the record is text.
--
-- The record (see PLAN.md § The store):
--
--   at, agent, session, pid, pane, transcript, cwd       the session
--   repo, path, file | dir, from, to, lang               the place
--   index, of                                            place N of M in the prompt
--   body, before, after                                  the lines, and 2 lines each side
--   head, tail, hash                                     the fast keys into the body
--   prompt                                               the first line of free text
--
-- `body` is the block's body, byte for byte: the photo of what the
-- conversation saw. The editor finds the lines again from it after the file
-- changed (lex.nvim, lua/lex/anchor.lua), so nothing here is ever updated.
-- `before` and `after` are read from the file at `path` now, and only when
-- the file's lines still say what the body says; they pick the right copy
-- when the same lines appear twice.
--
-- `pid` is this process's parent: `claude` in the exec form, and `codex` when
-- its shell hands over the process. The editor asks `kill(pid, 0)` to show
-- `working…`. `pane` is $TMUX_PANE, absent outside tmux.

local TAG = "lex-place"
local CAP = 200
local CONTEXT = 2

-- ── the block ──────────────────────────────────────────────────────────────

local UNESC = { amp = "&", lt = "<", gt = ">", quot = '"' }

local function attrs(s)
  local p = {}
  for k, v in s:gmatch('([%w_]+)="([^"]*)"') do
    p[k] = (v:gsub("&(%a+);", UNESC))
  end
  return p
end

local function finish(p)
  if p.n then
    p.n = tonumber(p.n)
    if not p.n then
      return nil
    end
  end
  if not (p.path and p.repo and (p.file or p.dir)) then
    return nil
  end
  return p
end

--- Every place in a prompt, in order, and the text that is left when the
--- blocks are taken out. A suffixed tag closes only with the same suffix.
--- When both forms match at the same spot the self-closing one wins: the open
--- form would otherwise swallow `<… dir="docs"/>` and everything up to the
--- next closing tag.
---@param text string
---@return table[] places, string free
local function parse(text)
  local places, free, pos = {}, {}, 1
  local name = TAG:gsub("%-", "%%-")
  local open = "<" .. name .. "(%-?%d*)(%s[^>]-)>\n?(.-)\n?</" .. name .. "%1>"
  local empty = "<" .. name .. "(%-?%d*)(%s[^>]-)/>"
  while true do
    local s, e, suf, a, body = text:find(open, pos)
    local s2, e2, suf2, a2 = text:find(empty, pos)
    if not s and not s2 then
      break
    end
    local p
    if s2 and (not s or s2 <= s) then
      s, e = s2, e2
      if suf2 == "" or suf2:match("^%-%d+$") then
        p = finish(attrs(a2))
      end
    elseif suf == "" or suf:match("^%-%d+$") then
      p = attrs(a)
      local from, to = (p.lines or ""):match("^(%d+)-(%d+)$")
      p.lines = nil
      from, to = tonumber(from), tonumber(to)
      if p.file and from and from >= 1 and from <= to then
        p.from, p.to, p.body = from, to, body
        p = finish(p)
      else
        p = nil
      end
    end
    free[#free + 1] = text:sub(pos, s - 1)
    if p then
      places[#places + 1] = p
    end
    pos = e + 1
  end
  free[#free + 1] = text:sub(pos)
  return places, table.concat(free)
end

-- ── what the lines said ────────────────────────────────────────────────────

--- The first CAP characters (code points, not bytes).
local function cap(s)
  return s:sub(1, vim.str_byteindex(s, "utf-32", CAP, false))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The first and the last non-blank line of a body, trimmed and capped.
local function head_tail(body)
  local head, tail
  for line in (body .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      head = head or line
      tail = line
    end
  end
  return head and cap(head), tail and cap(tail)
end

--- FNV-1a, 32 bits, over the body with every whitespace character removed,
--- as eight hex digits. Pure arithmetic, so any Lua gives the same answer:
--- the multiply by 16777619 (2^24 + 403) is split so nothing leaves the
--- exact range of a double.
local function fnv1a(body)
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

--- Up to CONTEXT raw lines before and after the range, read from the file
--- itself, only when its lines `from`..`to` still equal the body (a trailing
--- CR is ignored). A file that moved on, or is missing, gives no context.
--- Reads at most `to` + CONTEXT lines, so a large file costs nothing.
---@return string|nil before, string|nil after
local function context(p)
  local f = io.open(p.path, "r")
  if not f then
    return nil
  end
  local lines, i, last = {}, 0, p.to + CONTEXT
  for line in f:lines() do
    i = i + 1
    lines[i] = (line:gsub("\r$", ""))
    if i >= last then
      break
    end
  end
  f:close()
  if #lines < p.to or table.concat(lines, "\n", p.from, p.to) ~= p.body then
    return nil
  end
  local before, after
  if p.from > 1 then
    before = table.concat(lines, "\n", math.max(1, p.from - CONTEXT), p.from - 1)
  end
  if #lines > p.to then
    after = table.concat(lines, "\n", p.to + 1, math.min(#lines, p.to + CONTEXT))
  end
  return before, after
end

--- The first non-blank line of the free text, trimmed and capped.
local function first_line(free)
  for line in (free .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      return cap(line)
    end
  end
  return ""
end

-- ── the store ──────────────────────────────────────────────────────────────

local function home()
  local h = os.getenv("LEX_HOME")
  if h and h ~= "" then
    return h
  end
  return vim.uv.os_homedir() .. "/.lex"
end

local function slug(repo)
  return (repo:gsub("[^A-Za-z0-9]", "-"))
end

local function log(msg)
  pcall(function()
    local dir = home()
    vim.fn.mkdir(dir, "p")
    local f = io.open(dir .. "/hook.log", "a")
    if f then
      f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", msg, "\n")
      f:close()
    end
  end)
end

--- The session's state file. One small file, overwritten each time.
local function session_state(input, agent, state, pid, pane)
  local id = input.session_id
  if type(id) ~= "string" or id == "" or id:find("[/\\]") then
    return
  end
  local dir = home() .. "/sessions"
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/" .. id .. ".json", "w"))
  f:write(vim.json.encode({ state = state, at = os.time(), agent = agent, pid = pid, pane = pane, cwd = input.cwd }), "\n")
  f:close()
end

-- ── main ───────────────────────────────────────────────────────────────────

local function main()
  local agent = "claude"
  for i = 1, #_G.arg do
    if _G.arg[i] == "--agent" and _G.arg[i + 1] then
      agent = _G.arg[i + 1]
    end
  end

  local raw = io.read("*a") or ""
  local ok, input = pcall(vim.json.decode, raw)
  if not ok or type(input) ~= "table" then
    return
  end

  local now = os.time()
  local pid = vim.uv.os_getppid()
  local pane = os.getenv("TMUX_PANE")
  if pane == "" then
    pane = nil
  end

  local event = input.hook_event_name
  if event == "Stop" then
    session_state(input, agent, "idle", pid, pane)
    return
  elseif event == "SessionEnd" then
    session_state(input, agent, "ended", pid, pane)
    return
  elseif event == "SessionStart" then
    -- A compaction is not a new process and happens mid-answer; leave it.
    if input.source ~= "compact" then
      session_state(input, agent, "idle", pid, pane)
    end
    return
  elseif event ~= nil and event ~= "UserPromptSubmit" then
    return
  end
  if type(input.prompt) ~= "string" then
    return
  end
  session_state(input, agent, "working", pid, pane)

  local places, free = parse(input.prompt)
  if #places == 0 then
    return
  end
  local prompt = first_line(free)

  local by_repo, order = {}, {}
  for i, p in ipairs(places) do
    local r = {
      at = now,
      agent = agent,
      session = input.session_id,
      pid = pid,
      pane = pane,
      transcript = input.transcript_path,
      cwd = input.cwd,
      repo = p.repo,
      path = p.path,
      index = p.n or i,
      of = #places,
      prompt = prompt,
    }
    if p.dir then
      r.dir = p.dir
    else
      r.file = p.file
      if p.from then
        r.from, r.to = p.from, p.to
        if p.lang and p.lang ~= "" then
          r.lang = p.lang
        end
        r.body = p.body
        r.before, r.after = context(p)
        r.head, r.tail = head_tail(p.body)
        r.hash = fnv1a(p.body)
      end
    end
    if not by_repo[p.repo] then
      by_repo[p.repo] = {}
      order[#order + 1] = p.repo
    end
    table.insert(by_repo[p.repo], vim.json.encode(r))
  end

  for _, repo in ipairs(order) do
    local dir = home() .. "/" .. slug(repo)
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(dir .. "/links.jsonl", "a"))
    for _, line in ipairs(by_repo[repo]) do
      f:write(line, "\n")
    end
    f:close()
  end
end

local ok, err = pcall(main)
if not ok then
  log("error: " .. tostring(err))
end
os.exit(0)
