-- lex.place: the `<lex-place>` block.
--
-- A place is a file, a folder, or a run of whole lines in a file. The block is
-- what the editor puts on the clipboard and what every writer (the Claude
-- Code hook, the Codex hook, the OpenCode plugin) parses out of the prompt.
-- It is the contract. Change it here and in every writer, or in neither.
-- `contract/` holds the fixtures that keep the two sides equal.
--
--   <lex-place n="1" path="/abs/…/src/auth.ts" repo="/abs/…/aaa" file="src/auth.ts" lines="12-15" lang="typescript">
--   export function login(user: User) {
--   </lex-place>
--
--   <lex-place path="/abs/…/src/auth.ts" repo="/abs/…/aaa" file="src/auth.ts"/>     a whole file
--   <lex-place path="/abs/…/src/auth"    repo="/abs/…/aaa" dir="src/auth"/>         a folder
--
-- `path` is where the file really is, the worktree copy if that is where nvim
-- runs, because the agent's Read tool takes an absolute path. `repo` is the
-- main repository root, the parent of `git rev-parse --git-common-dir`, so a
-- worktree session and the main checkout share one store. `file` and `dir`
-- are relative to the checkout root, so a mark can find its buffer. `n` is
-- the user's own number for the place, the one the pending mark shows; it is
-- optional, and the hook falls back to the order of the blocks.
--
-- Three rules taken from Rex (rex, docs/my-specs/54-the-frame-around-the-text,
-- 2026-09-11), where the same problem was worked through first:
--
--   * Everything the tool knows about a place is an attribute. The body is
--     the selection itself and only that: never escaped, never fenced, never
--     re-indented. A model reads code best as code.
--   * Attribute values escape `&`, `<`, `>` and `"`. A body never does.
--   * A body that spells the tag does not break the block and is not
--     escaped: the tag is renamed instead. `<lex-place-1 …>…</lex-place-1>`,
--     with the smallest suffix that appears nowhere in the body, so the
--     closing tag is never ambiguous. Deterministic, checked, never hoped.
--     This matters the day Lex reviews its own repository with Lex.

local M = {}

M.TAG = "lex-place"

---@class lex.Place
---@field path string     absolute path of the file or folder
---@field repo string     absolute path of the main repository root
---@field file? string    relative to the checkout root; a file place
---@field dir? string     relative to the checkout root; a folder place
---@field from? integer   first line, 1-based, inclusive; absent for a whole file
---@field to? integer     last line, inclusive
---@field lang? string    nvim's filetype
---@field body? string    the lines, joined with "\n", no trailing newline
---@field n? integer      the user's own number for the place

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }
local UNESC = { amp = "&", lt = "<", gt = ">", quot = '"' }

local function attr(v)
  return (tostring(v):gsub('[&<>"]', ESC))
end

local function unattr(v)
  return (v:gsub("&(%a+);", UNESC))
end

--- The tag name a body allows: bare, or with the smallest suffix the body
--- does not spell. Searched for the open and the close form alike.
---@param body string|nil
---@return string
function M.tag_for(body)
  local name, k = M.TAG, 0
  if not body then
    return name
  end
  -- The hyphen in the name is a quantifier in a Lua pattern; escape it.
  local function spells(n)
    local pat = "<" .. n:gsub("%-", "%%-") .. "[%s>/]"
    return body:find(pat) or body:find("</" .. n .. ">", 1, true)
  end
  while spells(name) do
    k = k + 1
    name = M.TAG .. "-" .. k
  end
  return name
end

--- The block for a place.
---@param p lex.Place
---@return string
function M.block(p)
  local a = {}
  if p.n then
    a[#a + 1] = ('n="%d"'):format(p.n)
  end
  a[#a + 1] = ('path="%s"'):format(attr(p.path))
  a[#a + 1] = ('repo="%s"'):format(attr(p.repo))
  if p.dir then
    a[#a + 1] = ('dir="%s"'):format(attr(p.dir))
    return ("<%s %s/>"):format(M.TAG, table.concat(a, " "))
  end
  a[#a + 1] = ('file="%s"'):format(attr(p.file))
  if not p.from then
    return ("<%s %s/>"):format(M.TAG, table.concat(a, " "))
  end
  a[#a + 1] = ('lines="%d-%d"'):format(p.from, p.to)
  if p.lang and p.lang ~= "" then
    a[#a + 1] = ('lang="%s"'):format(attr(p.lang))
  end
  local tag = M.tag_for(p.body)
  return ("<%s %s>\n%s\n</%s>"):format(tag, table.concat(a, " "), p.body or "", tag)
end

local function attrs(s)
  local p = {}
  for k, v in s:gmatch('([%w_]+)="([^"]*)"') do
    p[k] = unattr(v)
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

--- Every place in a prompt, in order. The reference parser; each writer
--- carries its own copy in its own language, and `contract/` keeps them equal.
--- A suffixed tag closes only with the same suffix, so a body that spells a
--- bare tag cannot end a block early. When both forms match at the same spot
--- the self-closing one wins: the open form would otherwise swallow
--- `<… dir="docs"/>` and everything up to the next closing tag.
---@param text string
---@return lex.Place[]
function M.parse(text)
  local places, pos = {}, 1
  local name = M.TAG:gsub("%-", "%%-")
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
      e = e2
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
    if p then
      places[#places + 1] = p
    end
    pos = e + 1
  end
  return places
end

--- The main repository root and the checkout root for a path. Outside git,
--- both are the directory that holds the path.
---@param path string absolute
---@return string repo, string root
function M.roots(path)
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local ok, out = pcall(function()
    return vim.system(
      { "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel" },
      { text = true }
    ):wait()
  end)
  if not ok or out.code ~= 0 then
    return dir, dir
  end
  local common, top = out.stdout:match("^([^\n]*)\n([^\n]*)")
  -- `/main/.git` for a checkout and for a worktree alike. A submodule's
  -- common dir is `/super/.git/modules/sub`, which ends in no `/.git`; its
  -- own checkout root is the best key it has.
  local repo = common and common:match("^(.*)/%.git$") or top
  return repo or dir, top or dir
end

--- A path relative to a root: `.` for the root itself, the basename when the
--- path is not under the root at all.
---@param path string
---@param root string
---@return string
local function relative(path, root)
  if path == root then
    return "."
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return vim.fs.basename(path)
end
M.relative = relative

local function real(path)
  return vim.uv.fs_realpath(path) or path
end

--- The place for lines `from`..`to` of a buffer. The whole buffer is a
--- whole-file place: no lines, no body. A body of 400 lines helps nobody.
---@param buf integer
---@param from integer
---@param to integer
---@param n? integer the user's own number, from the pending list
---@return lex.Place
function M.for_buffer(buf, from, to, n)
  local path = real(vim.api.nvim_buf_get_name(buf))
  local repo, root = M.roots(path)
  local p = { n = n, path = path, repo = repo, file = relative(path, root) }
  if from == 1 and to >= vim.api.nvim_buf_line_count(buf) then
    return p
  end
  p.from, p.to = from, to
  p.lang = vim.bo[buf].filetype
  p.body = table.concat(vim.api.nvim_buf_get_lines(buf, from - 1, to, false), "\n")
  return p
end

--- The place for a path from a picker row: a file, or a folder.
---@param path string
---@param n? integer the user's own number, from the pending list
---@return lex.Place
function M.for_path(path, n)
  path = real(path)
  local repo, root = M.roots(path)
  local rel = relative(path, root)
  if vim.fn.isdirectory(path) == 1 then
    return { n = n, path = path, repo = repo, dir = rel }
  end
  return { n = n, path = path, repo = repo, file = rel }
end

--- One line for a notification: what was copied.
---@param p lex.Place
---@return string
function M.describe(p)
  if p.dir then
    return ("folder %s, every file under it"):format(p.dir)
  end
  local name = vim.fs.basename(p.path)
  if not p.from then
    return ("%s, whole file"):format(name)
  end
  if p.from == p.to then
    return ("line %d of %s"):format(p.from, name)
  end
  return ("lines %d-%d of %s"):format(p.from, p.to, name)
end

return M
