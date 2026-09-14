-- lex.store: where the links live, and how to read them.
--
--   $LEX_HOME/<repo-slug>--<hash>/links.jsonl      $LEX_HOME defaults to ~/.lex
--
-- The writers (agents/claude-code/hook.lua, agents/opencode/index.ts) append;
-- this side only reads. One record per line; a line that does not decode is
-- skipped, never fatal, because a writer may be mid-write on another core.
-- The record's fields are listed in PLAN.md § The store, and the writers' own
-- headers repeat them.

local M = {}

---@class lex.Record
---@field at integer          unix seconds
---@field agent string        "claude" | "codex" | "opencode"
---@field session string      the agent's own session id
---@field pid? integer        the agent process; kill(pid, 0) says running
---@field pane? string        $TMUX_PANE at prompt time
---@field transcript? string  the transcript file; absent for OpenCode
---@field cwd? string
---@field repo string         the main repository root
---@field path string         absolute path of the file or folder
---@field file? string        relative to the checkout root
---@field dir? string         a folder place
---@field from? integer
---@field to? integer
---@field lang? string
---@field index integer       place N of the prompt
---@field of integer          … of M
---@field body? string        the lines, byte for byte; what lex.anchor finds them by
---@field before? string      up to 2 raw lines before the range, when the file still matched
---@field after? string       up to 2 raw lines after it
---@field head? string        first non-blank line, trimmed, 200 characters at most
---@field tail? string        last non-blank line
---@field hash? string        FNV-1a of the body with whitespace removed
---@field prompt string       the first line of the free text

--- The store's home directory.
---@return string
function M.home()
  local h = os.getenv("LEX_HOME")
  if h and h ~= "" then
    return h
  end
  return vim.uv.os_homedir() .. "/.lex"
end

--- The old, lossy folder name. Kept only to migrate stores written by 0.1.0.
---@param repo string
---@return string
function M.legacy_slug(repo)
  return (repo:gsub("[^A-Za-z0-9]", "-"))
end

--- A readable, collision-resistant folder name for a repository. The exact
--- repo remains in every record and readers check it too; the hash keeps two
--- paths such as `/a-b/c` and `/a/b-c` out of the same file.
---@param repo string
---@return string
function M.slug(repo)
  local readable = repo:gsub("[^A-Za-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if readable == "" then
    readable = "repo"
  elseif #readable > 48 then
    readable = readable:sub(-48)
  end
  return readable .. "--" .. vim.fn.sha256(repo):sub(1, 16)
end

--- The links file for a repository.
---@param repo string
---@return string
function M.file(repo)
  return M.home() .. "/" .. M.slug(repo) .. "/links.jsonl"
end

---@param repo string
---@return string
function M.legacy_file(repo)
  return M.home() .. "/" .. M.legacy_slug(repo) .. "/links.jsonl"
end

local function key(rec)
  if rec.dir then
    return "dir:" .. rec.dir
  elseif not rec.from then
    return "file:" .. tostring(rec.file)
  end
  return ("range:%s:%d-%d"):format(tostring(rec.file), rec.from, rec.to)
end

local function matches(rec, tombstone)
  return rec.session == tombstone.session and (not tombstone.key or key(rec) == tombstone.key)
end

--- Decode an append-only store. A forget tombstone removes matching records
--- seen before it; a later prompt with the same session remains visible.
local function read_file(file, repo)
  local f = io.open(file, "r")
  if not f then
    return {}
  end
  local records = {}
  for line in f:lines() do
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" then
      if obj._lex == "forget" and obj.session then
        local kept = {}
        for _, rec in ipairs(records) do
          if not matches(rec, obj) then
            kept[#kept + 1] = rec
          end
        end
        records = kept
      elseif obj.path and obj.session and (not repo or obj.repo == repo) then
        records[#records + 1] = obj
      end
    end
  end
  f:close()
  return records
end

--- Copy this repository's new records from the old lossy store into its
--- hashed store. The byte offset lives in the new directory, one per exact
--- repo, so an old adapter that is still running can keep appending during an
--- upgrade. The old file is retained; exact filtering separates collisions.
---@param repo string
function M.migrate(repo)
  local legacy, file = M.legacy_file(repo), M.file(repo)
  local legacy_stat = vim.uv.fs_stat(legacy)
  if legacy == file or not legacy_stat then
    return
  end
  local marker = vim.fs.dirname(file) .. "/.migrated-v1"
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local lock = marker .. ".lock"
  local fd = vim.uv.fs_open(lock, "wx", 420)
  if not fd then
    return
  end
  local offset, marker_offset = 0, nil
  local mark = io.open(marker, "r")
  if mark then
    marker_offset = tonumber(mark:read("*l"))
    offset = marker_offset or 0
    mark:close()
  end
  if legacy_stat.size < offset then
    offset = 0
  end
  local existing = {}
  local current = io.open(file, "r")
  if current then
    for line in current:lines() do
      existing[line] = (existing[line] or 0) + 1
    end
    current:close()
  end
  local lines, next_offset = {}, offset
  local old = io.open(legacy, "r")
  if old then
    old:seek("set", offset)
    local data = old:read("*a") or ""
    local last = data:match(".*()\n")
    local chunk = last and data:sub(1, last) or ""
    next_offset = offset + #chunk
    for line in chunk:gmatch("(.-)\n") do
      local ok, rec = pcall(vim.json.decode, line)
      if ok and type(rec) == "table" and rec.repo == repo and rec.path and rec.session then
        if (existing[line] or 0) > 0 then
          existing[line] = existing[line] - 1
        else
          lines[#lines + 1] = line
        end
      end
    end
    old:close()
  end
  local migrated = true
  if #lines > 0 then
    local out = io.open(file, "a")
    if out then
      out:write(table.concat(lines, "\n"), "\n")
      out:close()
    else
      migrated = false
    end
  end
  if migrated and marker_offset ~= next_offset then
    local done = io.open(marker, "w")
    if done then
      done:write(tostring(next_offset), "\n")
      done:close()
    end
  end
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(lock)
end

--- Every record of a repository, in file order. An absent file is an empty
--- list.
---@param repo string
---@return lex.Record[]
function M.read(repo)
  M.migrate(repo)
  return read_file(M.file(repo), repo)
end

--- Forget records without rewriting the store. A tombstone applies to prior
--- matching records, while later prompts in the same session remain valid.
---@param repo string
---@param target { session: string, key?: string }
---@return integer removed, string|nil err
function M.forget(repo, target)
  M.migrate(repo)
  local file = M.file(repo)
  if not vim.uv.fs_stat(file) then
    return 0
  end
  local removed = 0
  for _, rec in ipairs(read_file(file, repo)) do
    if matches(rec, target) then
      removed = removed + 1
    end
  end
  if removed == 0 then
    return 0
  end
  local out = io.open(file, "a")
  if not out then
    return 0, "cannot append a forget marker to " .. file
  end
  out:write(vim.json.encode({ _lex = "forget", at = os.time(), session = target.session, key = target.key }), "\n")
  out:close()
  return removed
end

--- Every repository the store knows: slug and record count. For health.
---@return { slug: string, count: integer }[]
function M.repos()
  local out, repos = {}, {}
  local home = M.home()
  for name, kind in vim.fs.dir(home) do
    if kind == "directory" then
      local file = home .. "/" .. name .. "/links.jsonl"
      if vim.uv.fs_stat(file) then
        local f = io.open(file, "r")
        if f then
          for line in f:lines() do
            local ok, rec = pcall(vim.json.decode, line)
            if ok and type(rec) == "table" and rec.repo then
              repos[rec.repo] = true
            end
          end
          f:close()
        end
      end
    end
  end
  for repo in pairs(repos) do
    local canonical = M.file(repo)
    local file = vim.uv.fs_stat(canonical) and canonical or M.legacy_file(repo)
    out[#out + 1] = { slug = M.slug(repo), count = #read_file(file, repo) }
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out
end

return M
