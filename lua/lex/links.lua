-- lex.links: the store in memory, one table per repository.
--
-- The file is read once, then only its tail: the byte offset after the last
-- complete line is remembered, and a change reads what came after it. A
-- writer may be mid-line when we look, so a trailing partial line waits for
-- the next read. A file that got shorter was rewritten (a "forget" command,
-- later) and is read again from the start.
--
-- A watcher on the store folder and `FocusGained` both trigger a read; the
-- `User LexStoreChanged` autocmd tells the marks and the pending list. Two
-- questions every reader asks are answered here too: is the session still
-- running (`kill(pid, 0)`), and is its transcript gone.
--
-- `roots()` finds the repository of a path without git: walk up to `.git`,
-- and read the `gitdir:` line of a worktree's `.git` file to find the main
-- checkout. The explorer asks this per visible row, so it must not spawn.
-- The answer equals `lex.place.roots()`, which the block uses (tested).

local store = require("lex.store")

local M = {}

---@class lex.Repo
---@field repo string
---@field file string                 links.jsonl
---@field records lex.Record[]
---@field by_file table<string, lex.Record[]>
---@field dirs lex.Record[]           folder places
---@field offset integer              bytes read so far
---@field watcher? uv.uv_fs_event_t
---@field watching? string            the folder the watcher is on

---@type table<string, lex.Repo>
M.repos = {}

local roots_cache = {} ---@type table<string, { [1]: string, [2]: string }>

local function real(path)
  return vim.uv.fs_realpath(path) or path
end

--- The main repository root and the checkout root, from the file system.
---@param path string absolute
---@return string repo, string root
function M.roots(path)
  path = real(path)
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local hit = roots_cache[dir]
  if hit then
    return hit[1], hit[2]
  end
  local top, repo
  local d = dir
  while d do
    local st = vim.uv.fs_stat(d .. "/.git")
    if st then
      top = d
      repo = d
      if st.type == "file" then
        local f = io.open(d .. "/.git", "r")
        local line = f and f:read("*l") or ""
        if f then
          f:close()
        end
        local gitdir = line:match("^gitdir:%s*(.-)%s*$")
        if gitdir then
          if gitdir:sub(1, 1) ~= "/" then
            gitdir = vim.fs.normalize(d .. "/" .. gitdir)
          end
          local main = gitdir:match("^(.*)/%.git/worktrees/[^/]+$")
          if main then
            repo = real(main)
          end
        end
      end
      break
    end
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    d = parent
  end
  repo, top = repo or dir, top or dir
  roots_cache[dir] = { repo, top }
  return repo, top
end

local function add(r, rec)
  r.records[#r.records + 1] = rec
  if rec.dir then
    r.dirs[#r.dirs + 1] = rec
  elseif rec.file then
    local list = r.by_file[rec.file]
    if not list then
      list = {}
      r.by_file[rec.file] = list
    end
    list[#list + 1] = rec
  end
end

local function reset(r)
  r.records, r.by_file, r.dirs, r.offset = {}, {}, {}, 0
end

--- Read what is new in the file. Returns whether anything was added.
---@param r lex.Repo
---@return boolean
function M.refresh(r)
  local st = vim.uv.fs_stat(r.file)
  if not st then
    if r.offset > 0 then
      reset(r)
      return true
    end
    return false
  end
  if st.size < r.offset then
    reset(r)
  end
  if st.size == r.offset then
    return false
  end
  local f = io.open(r.file, "r")
  if not f then
    return false
  end
  f:seek("set", r.offset)
  local data = f:read("*a") or ""
  f:close()
  local last = data:match(".*()\n")
  if not last then
    return false
  end
  local chunk = data:sub(1, last)
  r.offset = r.offset + #chunk
  local added = 0
  for line in chunk:gmatch("(.-)\n") do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" and rec.path and rec.session then
      add(r, rec)
      added = added + 1
    end
  end
  return added > 0
end

local function changed(r)
  vim.api.nvim_exec_autocmds("User", { pattern = "LexStoreChanged", data = { repo = r.repo }, modeline = false })
end

local function watch(r)
  local dir = vim.fs.dirname(r.file)
  local target = vim.fn.isdirectory(dir) == 1 and dir or store.home()
  if r.watching == target then
    return
  end
  if r.watcher then
    r.watcher:stop()
    r.watcher:close()
    r.watcher = nil
  end
  vim.fn.mkdir(store.home(), "p")
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local pending = false
  local ok = handle:start(target, {}, function()
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      if M.refresh(r) then
        changed(r)
      end
      watch(r)
    end, 100)
  end)
  if ok then
    r.watcher, r.watching = handle, target
  else
    handle:close()
  end
end

--- The repository's table, loaded on first use.
---@param repo string
---@return lex.Repo
function M.repo(repo)
  local r = M.repos[repo]
  if r then
    return r
  end
  r = { repo = repo, file = store.file(repo), records = {}, by_file = {}, dirs = {}, offset = 0 }
  M.repos[repo] = r
  M.refresh(r)
  watch(r)
  return r
end

--- Read every loaded repository again. `FocusGained` calls this.
function M.refresh_all()
  M.forget_sessions()
  for _, r in pairs(M.repos) do
    if M.refresh(r) then
      changed(r)
    end
  end
end

local sessions_watcher

--- Watch the sessions folder: a state flips, the badges follow at once.
function M.watch_sessions()
  if sessions_watcher then
    return
  end
  local dir = store.home() .. "/sessions"
  vim.fn.mkdir(dir, "p")
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local pending = false
  local ok = handle:start(dir, {}, function()
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      M.forget_sessions()
      vim.api.nvim_exec_autocmds("User", { pattern = "LexSessionChanged", modeline = false })
    end, 100)
  end)
  if ok then
    sessions_watcher = handle
  else
    handle:close()
  end
end

--- Does a folder place cover a path?
---@param dir string   relative, `.` for the root
---@param rel string   relative
---@return boolean
function M.covers(dir, rel)
  return dir == "." or rel == dir or rel:sub(1, #dir + 1) == dir .. "/"
end

--- Every record that applies to a file: its own, and the folder places above
--- it. Ranges and whole-file places first, folders after.
---@param repo string
---@param file string relative
---@return lex.Record[]
function M.for_file(repo, file)
  local r = M.repo(repo)
  local out = {}
  for _, rec in ipairs(r.by_file[file] or {}) do
    out[#out + 1] = rec
  end
  for _, rec in ipairs(r.dirs) do
    if M.covers(rec.dir, file) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- The folder places on exactly this folder.
---@param repo string
---@param dir string relative
---@return lex.Record[]
function M.on_dir(repo, dir)
  local out = {}
  for _, rec in ipairs(M.repo(repo).dirs) do
    if rec.dir == dir then
      out[#out + 1] = rec
    end
  end
  return out
end

--- The folder places strictly above a path.
---@param repo string
---@param rel string relative
---@return lex.Record[]
function M.above(repo, rel)
  local out = {}
  for _, rec in ipairs(M.repo(repo).dirs) do
    if rec.dir ~= rel and M.covers(rec.dir, rel) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Everything under a folder: files below it and folder places on or below
--- it. The picker's folder scope.
---@param repo string
---@param dir string relative
---@return lex.Record[]
function M.under_dir(repo, dir)
  local r = M.repo(repo)
  local out = {}
  for _, rec in ipairs(r.records) do
    local rel = rec.file or rec.dir
    if rel and M.covers(dir, rel) then
      out[#out + 1] = rec
    end
  end
  return out
end

local session_cache = {} ---@type table<string, { at: number, state: table|nil }>

--- The session's state file, cached for two seconds: the badges repaint on
--- every cursor move and must not read a file each time.
---@param session string
---@return table|nil
function M.session_state(session)
  local now = vim.uv.now()
  local c = session_cache[session]
  if c and now - c.at < 2000 then
    return c.state
  end
  local st
  local f = io.open(store.home() .. "/sessions/" .. session .. ".json", "r")
  if f then
    local ok, obj = pcall(vim.json.decode, f:read("*a") or "")
    f:close()
    if ok and type(obj) == "table" then
      st = obj
    end
  end
  session_cache[session] = { at = now, state = st }
  return st
end

--- Forget the cached session states; the watcher on the sessions folder
--- calls this when a file changed.
function M.forget_sessions()
  session_cache = {}
end

---@class lex.Where
---@field pid? integer
---@field pane? string
---@field state? "working"|"idle"|"ended"

--- Where the session is now: the pid and the pane from its state file,
--- which every start, resume, prompt and stop rewrite; the record's own
--- when there is no state file (a record from before the state files). An
--- `ended` session has no pid and no pane.
---@param rec lex.Record
---@return lex.Where
function M.where(rec)
  local st
  if rec.session and not rec.session:find("[/\\]") then
    st = M.session_state(rec.session)
  end
  if st and st.state == "ended" then
    return { state = "ended" }
  end
  return { pid = st and st.pid or rec.pid, pane = st and st.pane or rec.pane, state = st and st.state or nil }
end

--- Does the session's process still exist? Idle or working, an alive
--- session has a window somewhere, and that is where `<CR>` goes.
---@param rec lex.Record
---@return boolean
function M.alive(rec)
  local w = M.where(rec)
  return w.pid ~= nil and vim.uv.kill(w.pid, 0) == 0
end

--- Is the session working on an answer right now? The state file says
--- `working` from the prompt to the Stop hook, and the process must still
--- be alive: a session killed mid-answer never writes `idle`. A record from
--- a session without a state file is not working; a process id alone
--- proved nothing, an idle agent is a living process too.
---@param rec lex.Record
---@return boolean
function M.running(rec)
  local w = M.where(rec)
  return w.state == "working" and w.pid ~= nil and vim.uv.kill(w.pid, 0) == 0
end

--- Was the transcript deleted? OpenCode keeps none, so never for it.
---@param rec lex.Record
---@return boolean
function M.gone(rec)
  if not rec.transcript or rec.transcript == "" then
    return false
  end
  local now = os.time()
  if rec._gone_at and now - rec._gone_at < 60 then
    return rec._gone
  end
  rec._gone_at = now
  rec._gone = vim.uv.fs_stat(rec.transcript) == nil
  return rec._gone
end

--- "now", "12m", "2h", "3d", "2mo".
---@param at integer unix seconds
---@return string
function M.age(at)
  local s = os.time() - (at or 0)
  if s < 60 then
    return "now"
  elseif s < 3600 then
    return ("%dm"):format(s / 60)
  elseif s < 86400 then
    return ("%dh"):format(s / 3600)
  elseif s < 30 * 86400 then
    return ("%dd"):format(s / 86400)
  end
  return ("%dmo"):format(s / (30 * 86400))
end

-- ── forgetting ─────────────────────────────────────────────────────────────

--- Drop records, reload the repository from scratch, and tell the editor.
---@param repo string
---@param drop fun(rec: lex.Record): boolean
---@return integer removed, string|nil err
local function forget(repo, drop)
  local removed, err = store.forget(repo, drop)
  if removed > 0 then
    local r = M.repo(repo)
    reset(r)
    M.refresh(r)
    changed(r)
  end
  return removed, err
end

--- Forget every record of a conversation in a repository.
---@param repo string
---@param session string
---@return integer removed, string|nil err
function M.forget_session(repo, session)
  return forget(repo, function(rec)
    return rec.session == session
  end)
end

--- Forget one place of a conversation: every record with the same session
--- and the same file, folder or range.
---@param repo string
---@param session string
---@param key string   from lex.conv.key
---@return integer removed, string|nil err
function M.forget_place(repo, session, key)
  local conv = require("lex.conv")
  return forget(repo, function(rec)
    return rec.session == session and conv.key(rec) == key
  end)
end

--- Forget the cached roots; tests call it between repositories.
function M.reset_cache()
  roots_cache = {}
end

return M
