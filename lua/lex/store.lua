-- lex.store: where the links live, and how to read them.
--
--   $LEX_HOME/<repo-slug>/links.jsonl      $LEX_HOME defaults to ~/.lex
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

--- The folder name for a repository: every character that is not a letter or
--- a digit becomes `-`, the rule Claude Code uses for ~/.claude/projects/.
---@param repo string
---@return string
function M.slug(repo)
  return (repo:gsub("[^A-Za-z0-9]", "-"))
end

--- The links file for a repository.
---@param repo string
---@return string
function M.file(repo)
  return M.home() .. "/" .. M.slug(repo) .. "/links.jsonl"
end

--- Every record of a repository, in file order. An absent file is an empty
--- list.
---@param repo string
---@return lex.Record[]
function M.read(repo)
  local f = io.open(M.file(repo), "r")
  if not f then
    return {}
  end
  local records = {}
  for line in f:lines() do
    local ok, r = pcall(vim.json.decode, line)
    if ok and type(r) == "table" and r.path and r.session then
      records[#records + 1] = r
    end
  end
  f:close()
  return records
end

--- Drop records from a repository's file: the one thing that is not an
--- append. `drop(rec)` says which. The file is rewritten under a lock and
--- moved into place, so a reader never sees half a file.
---
--- A writer does not take the lock: an append of one line is atomic, and a
--- hook must never wait on an editor. So a record appended between the read
--- and the move would be lost; the size is checked after the move and the
--- work is redone when it changed. Rare by construction, since this runs
--- when a person picks "forget" and a prompt lands in the same millisecond.
---@param repo string
---@param drop fun(rec: lex.Record): boolean
---@return integer removed, string|nil err
function M.forget(repo, drop)
  local file = M.file(repo)
  if not vim.uv.fs_stat(file) then
    return 0
  end
  local lock = file .. ".lock"
  local fd
  for _ = 1, 50 do
    fd = vim.uv.fs_open(lock, "wx", 420)
    if fd then
      break
    end
    vim.uv.sleep(20)
  end
  if not fd then
    return 0, "another nvim is writing " .. file
  end
  local removed, err = 0, nil
  for _ = 1, 3 do
    local before = vim.uv.fs_stat(file)
    local kept = {}
    removed = 0
    for line in io.lines(file) do
      local ok, rec = pcall(vim.json.decode, line)
      if ok and type(rec) == "table" and drop(rec) then
        removed = removed + 1
      else
        kept[#kept + 1] = line
      end
    end
    if removed == 0 then
      break
    end
    local tmp = file .. ".tmp"
    local out = io.open(tmp, "w")
    if not out then
      err = "cannot write " .. tmp
      break
    end
    for _, line in ipairs(kept) do
      out:write(line, "\n")
    end
    out:close()
    local after = vim.uv.fs_stat(file)
    if after and before and after.size ~= before.size then
      vim.fn.delete(tmp)
    else
      local ok, e = vim.uv.fs_rename(tmp, file)
      if not ok then
        err = tostring(e)
      end
      break
    end
  end
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(lock)
  return removed, err
end

--- Every repository the store knows: slug and record count. For health.
---@return { slug: string, count: integer }[]
function M.repos()
  local out = {}
  local home = M.home()
  for name, kind in vim.fs.dir(home) do
    if kind == "directory" then
      local n = 0
      local f = io.open(home .. "/" .. name .. "/links.jsonl", "r")
      if f then
        for _ in f:lines() do
          n = n + 1
        end
        f:close()
        out[#out + 1] = { slug = name, count = n }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out
end

return M
