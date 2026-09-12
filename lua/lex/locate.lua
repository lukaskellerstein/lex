-- lex.locate: where a session is running right now.
--
-- A record remembers the process and the pane of the moment the prompt was
-- sent. Neither survives a restart, and a stored pane is worse than useless
-- once another session takes it over: jumping there shows the wrong
-- conversation (seen 2026-09-12, a Codex row opened a different Codex). So
-- nothing here trusts a stored pane. Every answer is derived from a process
-- that is alive now and proved to be this session, and the pane comes from
-- that process's own place in the tree.
--
-- Three proofs, tried in order, each exact:
--
--   1. the state file: the writer wrote "I am session X, pid P" on its last
--      start, prompt or stop, and P is still alive. Covers a session that
--      never left, and a Claude Code session resumed from its own picker
--      (SessionStart fires with the same id).
--   2. the command line: a process whose arguments carry the session id.
--      Covers every resume by id: `claude --resume X`, `codex resume X`,
--      `opencode -s X`, however it was started, and it works even when the
--      agent gives the resumed session a new id of its own, which Codex
--      does (measured 2026-09-12: `codex resume` writes a new rollout with
--      a new id, so the state file can never match the old one).
--   3. the session file, held open: `lsof` on the record's transcript.
--      Codex keeps its rollout open; Claude Code does not (measured), and
--      OpenCode has no per-session file, so this is the Codex case.
--
-- Then the pid walks up its parents until one of them is a tmux pane's
-- process. No pane means the agent runs in a bare terminal window; the pid
-- is still returned, and the machine's own opener can focus the window from
-- it (mac-setup: yabai knows a window by pid).

local M = {}

---@class lex.Location
---@field pid integer
---@field pane? string     the tmux pane, when it is in tmux
---@field how "state"|"argv"|"file"

---@class lex.Proc
---@field pid integer
---@field ppid integer
---@field cmd string

--- Every process, as `ps` reports it. One call, parsed.
--- `-ww` so a long command line is not cut at the terminal width.
---@param text? string for the test
---@return table<integer, lex.Proc>
function M.processes(text)
  if not text then
    local out = vim.system({ "ps", "-axww", "-o", "pid=,ppid=,command=" }, { text = true }):wait()
    text = out.code == 0 and out.stdout or ""
  end
  local procs = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local pid, ppid, cmd = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      procs[tonumber(pid)] = { pid = tonumber(pid), ppid = tonumber(ppid), cmd = cmd }
    end
  end
  return procs
end

---@class lex.Pane
---@field pane string      `%123`
---@field pid integer      the process the pane runs
---@field session string   the tmux session's name
---@field index integer    the window's number in that session
---@field name string      the window's name, which tmux sets from its command

--- Every tmux pane, with the window it sits in. Tab separated, because a
--- window's name can hold spaces.
---@param text? string for the test
---@return lex.Pane[]
function M.panes_full(text)
  if not text then
    local out = vim.system({
      "tmux",
      "list-panes",
      "-a",
      "-F",
      "#{pane_id}\t#{pane_pid}\t#{session_name}\t#{window_index}\t#{window_name}",
    }, { text = true }):wait()
    text = out.code == 0 and out.stdout or ""
  end
  local rows = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local pane, pid, session, index, name = line:match("^(%%%d+)\t(%d+)\t([^\t]*)\t(%d+)\t(.*)$")
    if pane then
      rows[#rows + 1] = { pane = pane, pid = tonumber(pid), session = session, index = tonumber(index), name = name }
    end
  end
  return rows
end

--- The tmux panes, as pane process id → pane id.
---@param text? string for the test, in the two-field form `pid pane`
---@return table<integer, string>
function M.panes(text)
  local panes = {}
  if not text then
    for _, row in ipairs(M.panes_full()) do
      panes[row.pid] = row.pane
    end
    return panes
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local pid, pane = line:match("^(%d+)%s+(%%%d+)$")
    if pid then
      panes[tonumber(pid)] = pane
    end
  end
  return panes
end

---@class lex.Snapshot
---@field procs table<integer, lex.Proc>
---@field panes table<integer, string>
---@field pane_info table<string, lex.Pane>

--- One reading of the machine, for resolving many sessions at once: a
--- picker asks about every row, and a `ps` per row would be absurd.
---@return lex.Snapshot
function M.snapshot()
  local rows = M.panes_full()
  local panes, info = {}, {}
  for _, row in ipairs(rows) do
    panes[row.pid] = row.pane
    info[row.pane] = row
  end
  return { procs = M.processes(), panes = panes, pane_info = info }
end

--- A process and its parents, nearest first, up to but not including pid 1.
--- The window a session is displayed in belongs to one of these: the agent,
--- the shell, the terminal. A cycle or a missing parent ends the walk.
---
--- Nearest first matters, and a caller must take the FIRST ancestor that
--- answers, not any: the chain does not stop at the session's own terminal.
--- It goes on to whoever launched it, which for a terminal Lex opened is
--- this nvim, whose own ancestors reach the terminal app showing nvim, and
--- that app owns every other window on the desktop (2026-09-12).
---@param pid integer
---@param procs table<integer, lex.Proc>
---@return integer[]
function M.ancestors(pid, procs)
  local out, seen, p = {}, {}, pid
  for _ = 1, 40 do
    if not p or p <= 1 or seen[p] then
      break
    end
    out[#out + 1] = p
    seen[p] = true
    local proc = procs[p]
    if not proc then
      break
    end
    p = proc.ppid
  end
  return out
end

--- The tmux pane a process sits in: itself, or the nearest ancestor that is
--- a pane's process. Nil outside tmux.
---@param pid integer
---@param procs table<integer, lex.Proc>
---@param panes table<integer, string>
---@return string|nil
function M.pane_of(pid, procs, panes)
  for _, p in ipairs(M.ancestors(pid, procs)) do
    if panes[p] then
      return panes[p]
    end
  end
  return nil
end

--- The processes whose command line carries the session id.
---
--- With a known agent, only the agent's own processes count: `claude`,
--- `codex` or `opencode` as the program being run. Everything else that
--- mentions an id is something talking *about* the session, not running it:
--- the terminal that spawned it (`ghostty … -e opencode -s <id>`), a shell
--- one-liner, a `grep`. Taking one of those as the answer sends the jump to
--- a window that has nothing to do with the conversation (seen 2026-09-12,
--- where a shell holding three ids in its command line was found for all
--- three). The terminal is reached anyway, through the agent's parents.
---
--- Without an agent, anything that names the id is a candidate.
---@param session string
---@param procs table<integer, lex.Proc>
---@param agent? string
---@return integer[]
function M.by_argv(session, procs, agent)
  local me = vim.uv.os_getpid()
  local bin = ({ claude = "claude", codex = "codex", opencode = "opencode" })[agent or ""]
  local hits = {}
  for pid, p in pairs(procs) do
    if pid ~= me and p.cmd:find(session, 1, true) then
      local first = p.cmd:match("^%S+") or ""
      if not bin or vim.fs.basename(first) == bin then
        hits[#hits + 1] = pid
      end
    end
  end
  table.sort(hits)
  return hits
end

--- The processes holding files open, as path → pid. One `lsof` however
--- many paths, because it costs about 180 ms whatever it is asked
--- (measured 2026-09-12) and a list asks about every row at once.
--- `-F pn` prints a `p<pid>` line and then an `n<path>` line per file.
---@param paths string[]
---@param text? string for the test
---@return table<string, integer>
function M.by_open_files(paths, text)
  local out = {}
  local want = {}
  local args = { "lsof", "-F", "pn", "--" }
  for _, p in ipairs(paths) do
    if p and p ~= "" and vim.uv.fs_stat(p) then
      want[p] = true
      args[#args + 1] = p
    end
  end
  if not text then
    if #args == 4 or vim.fn.executable("lsof") ~= 1 then
      return out
    end
    -- lsof answers non-zero when any of the files is open by nobody, which
    -- is an ordinary answer here, so the text is read either way.
    local res = vim.system(args, { text = true }):wait(5000)
    text = res and res.stdout or ""
  end
  local pid
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local tag, rest = line:sub(1, 1), line:sub(2)
    if tag == "p" then
      pid = tonumber(rest)
    elseif tag == "n" and pid and (want[rest] or not next(want)) then
      out[rest] = out[rest] or pid
    end
  end
  return out
end

--- The process holding one file open, if any.
---@param path string|nil
---@return integer|nil
function M.by_open_file(path)
  if not path then
    return nil
  end
  return M.by_open_files({ path })[path]
end

--- The state file's pid, when the session did not end and it is still alive.
---@param rec lex.Record
---@return integer|nil
local function by_state(rec)
  local links = require("lex.links")
  if not rec.session or rec.session:find("[/\\]") then
    return nil
  end
  local st = links.session_state(rec.session)
  if not st or st.state == "ended" or not st.pid then
    return nil
  end
  return vim.uv.kill(st.pid, 0) == 0 and st.pid or nil
end

--- Where the session is now, or nil.
---@param rec lex.Record
---@param snap? lex.Snapshot  one reading of the machine, for many sessions
---@return lex.Location|nil
function M.locate(rec, snap)
  if not rec.session then
    return nil
  end
  local procs, panes
  local function tree()
    if not procs then
      if snap then
        procs, panes = snap.procs, snap.panes
      else
        procs, panes = M.processes(), M.panes()
      end
    end
    return procs, panes
  end

  local pid, how = by_state(rec), "state"
  if not pid then
    local ps, pn = tree()
    local hits = M.by_argv(rec.session, ps, rec.agent)
    for _, candidate in ipairs(hits) do
      if M.pane_of(candidate, ps, pn) then
        pid = candidate
        break
      end
    end
    pid = pid or hits[1]
    how = "argv"
  end
  if not pid then
    pid = M.by_open_file(M.session_file(rec))
    how = "file"
  end
  if not pid then
    return nil
  end
  local ps, pn = tree()
  return { pid = pid, pane = M.pane_of(pid, ps, pn), how = how }
end

--- The file whose reader proves a session is running: only Codex keeps its
--- rollout open. Claude Code appends to its transcript and closes it again
--- and OpenCode has no per-session file (both measured 2026-09-12), so
--- probing those costs 180 ms and can only answer no.
--- Declared before `locate` uses it at run time; Lua resolves it then.
---@param rec lex.Record
---@return string|nil
function M.session_file(rec)
  if rec.agent ~= "codex" then
    return nil
  end
  if rec.transcript and rec.transcript ~= "" and vim.uv.fs_stat(rec.transcript) then
    return rec.transcript
  end
  local home = os.getenv("CODEX_HOME")
  if not home or home == "" then
    home = vim.uv.os_homedir() .. "/.codex"
  end
  local hits = vim.fn.glob(home .. "/sessions/*/*/*/rollout-*-" .. rec.session .. ".jsonl", false, true)
  return hits[1]
end

--- Where several sessions are, in one reading of the machine: one `ps`,
--- one `tmux list-panes`, and at most one `lsof` for every session that the
--- first two could not place. What a list needs.
---@param recs lex.Record[]
---@param snap? lex.Snapshot
---@return table<lex.Record, lex.Location>
function M.locate_many(recs, snap)
  snap = snap or M.snapshot()
  local out, pending, paths = {}, {}, {}
  for _, rec in ipairs(recs) do
    if rec.session then
      local pid, how = by_state(rec), "state"
      if not pid then
        for _, candidate in ipairs(M.by_argv(rec.session, snap.procs, rec.agent)) do
          pid, how = candidate, "argv"
          if M.pane_of(candidate, snap.procs, snap.panes) then
            break
          end
        end
      end
      if pid then
        out[rec] = { pid = pid, pane = M.pane_of(pid, snap.procs, snap.panes), how = how }
      else
        local path = M.session_file(rec)
        if path and not pending[path] then
          pending[path] = rec
          paths[#paths + 1] = path
        end
      end
    end
  end
  for path, pid in pairs(M.by_open_files(paths)) do
    local rec = pending[path]
    if rec then
      out[rec] = { pid = pid, pane = M.pane_of(pid, snap.procs, snap.panes), how = "file" }
    end
  end
  return out
end

--- Where a session is, in words, for a list: `tmux ai-evaluation:3 claude`
--- for a pane, `terminal` for a window with no tmux, nothing when it is not
--- running. `config.where` may add what only this machine can know, the
--- desktop for instance; it is called once per row, so it should cache.
---@param loc lex.Location|nil
---@param snap? lex.Snapshot
---@return string|nil
function M.describe(loc, snap)
  if not loc then
    return nil
  end
  local parts = {}
  local info = loc.pane and snap and snap.pane_info[loc.pane]
  if info then
    local where = ("tmux %s:%d"):format(info.session, info.index)
    -- The window's name is tmux's own, so it is the running command unless
    -- somebody named the window. A name worth showing is one that says
    -- something: `pr-64-review`, or the short session id Lex gives a window
    -- it opens. A bare version number, which is what Claude Code calls
    -- itself, is not.
    local name = info.name
    if name ~= "" and not name:match("^[%d.]+$") and not where:find(name, 1, true) then
      where = where .. " " .. name
    end
    parts[#parts + 1] = where
  elseif loc.pane then
    parts[#parts + 1] = "tmux " .. loc.pane
  else
    parts[#parts + 1] = "terminal"
  end
  local extra = require("lex").config.where
  if type(extra) == "function" then
    local ok, text = pcall(extra, loc, snap)
    if ok and type(text) == "string" and text ~= "" then
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, " · ")
end

return M
