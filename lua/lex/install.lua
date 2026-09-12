-- lex.install: wire the writer into each agent, idempotently.
--
--   :LexInstallHook            Claude Code   ~/.claude/settings.json
--   :LexInstallHook codex      Codex         ~/.codex/config.toml
--   :LexInstallHook opencode   OpenCode      ~/.config/opencode/plugin/lex.ts
--
-- Each command edits the agent's own file in place. On a machine where the
-- file is a symlink into a dotfiles repository, `io.open(path, "w")` writes
-- through the link and the link stays. Each is safe to run twice: the second
-- run finds its own entry and changes nothing.
--
-- Absolute paths everywhere. `vim.fn.exepath("nvim")` gives the nvim on PATH
-- (`/opt/homebrew/bin/nvim` on a Mac with Homebrew), not `vim.v.progpath`,
-- which can be the Cellar path with the version in it and break on the next
-- upgrade. A session started from the desktop app has a shorter PATH than a
-- terminal, so the hook entry never relies on PATH at all.
--
-- Each agent honours one environment variable for its home, and so does this:
-- `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`. The tests use them to
-- install into a temporary directory.

local json = require("lex.json")

local M = {}

--- The checkout this file lives in, absolute even when the runtimepath entry
--- that loaded it was relative (the tests do that).
local function plugin_root()
  local src = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(src))))
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

--- The writer, inside this checkout of lex.nvim.
function M.hook_path()
  return plugin_root() .. "/agents/claude-code/hook.lua"
end

--- The OpenCode plugin source, inside this checkout.
function M.opencode_source()
  return plugin_root() .. "/agents/opencode/index.ts"
end

--- The nvim the hook entry names.
function M.nvim_path()
  local p = vim.fn.exepath("nvim")
  if p == "" then
    p = vim.v.progpath
  end
  return vim.fs.normalize(p)
end

--- The three files the installers touch.
---@return { claude: string, codex: string, opencode: string }
function M.paths()
  local home = vim.uv.os_homedir()
  local function env(name, default)
    local v = os.getenv(name)
    if v and v ~= "" then
      return v
    end
    return default
  end
  return {
    claude = env("CLAUDE_CONFIG_DIR", home .. "/.claude") .. "/settings.json",
    codex = env("CODEX_HOME", home .. "/.codex") .. "/config.toml",
    opencode = env("XDG_CONFIG_HOME", home .. "/.config") .. "/opencode/plugin/lex.ts",
  }
end

-- ── Claude Code ────────────────────────────────────────────────────────────

--- The events the writer needs: the prompt, the end of the answer, and the
--- start and end of the session, for the pid and pane of the moment.
M.EVENTS = { "UserPromptSubmit", "Stop", "SessionStart", "SessionEnd" }

--- Our hook among an event's entries of a decoded settings object: any
--- `args` whose script ends in `agents/claude-code/hook.lua`.
---@return lex.json.Object|nil hook, string|nil command, string|nil script
local function find_claude(root, event)
  local hooks = root:get("hooks")
  local list = json.is_object(hooks) and hooks:get(event)
  for _, entry in ipairs(type(list) == "table" and list or {}) do
    local hs = json.is_object(entry) and entry:get("hooks")
    for _, h in ipairs(type(hs) == "table" and hs or {}) do
      local args = json.is_object(h) and h:get("args")
      local script = type(args) == "table" and args[2]
      if type(script) == "string" and script:match("agents/claude%-code/hook%.lua$") then
        return h, h:get("command"), script
      end
    end
  end
end

--- The status of several parts: "installed" when any was added, else
--- "updated" when any changed, else "present".
local function worst(statuses)
  local out = "present"
  for _, s in ipairs(statuses) do
    if s == "installed" then
      return s
    elseif s == "updated" then
      out = s
    end
  end
  return out
end

--- Install into Claude Code's settings.json: one entry each for
--- UserPromptSubmit and Stop, the same command. Returns what happened and
--- the file: "installed", "updated" (an entry pointed at an older path), or
--- "present".
---@return string status, string file
function M.claude()
  local file = M.paths().claude
  local text = read(file)
  local root = text and json.decode(text) or json.object()
  if not json.is_object(root) then
    error(file .. " is not a JSON object", 0)
  end
  local nvim, hook = M.nvim_path(), M.hook_path()
  local statuses = {}
  for _, event in ipairs(M.EVENTS) do
    local h, command, script = find_claude(root, event)
    if h then
      if command == nvim and script == hook then
        statuses[#statuses + 1] = "present"
      else
        h:set("command", nvim)
        h:set("args", json.array({ "-l", hook }))
        statuses[#statuses + 1] = "updated"
      end
    else
      local hooks = root:get("hooks")
      if not json.is_object(hooks) then
        hooks = json.object()
        root:set("hooks", hooks)
      end
      local list = hooks:get(event)
      if type(list) ~= "table" then
        list = json.array()
        hooks:set(event, list)
      end
      h = json.object()
      h:set("type", "command")
      h:set("command", nvim)
      h:set("args", json.array({ "-l", hook }))
      h:set("timeout", 5)
      local entry = json.object()
      entry:set("hooks", json.array({ h }))
      list[#list + 1] = entry
      statuses[#statuses + 1] = "installed"
    end
  end
  local status = worst(statuses)
  if status ~= "present" then
    write(file, json.encode(root) .. "\n")
  end
  return status, file
end

-- ── Codex ──────────────────────────────────────────────────────────────────

--- A path as one shell word: bare when it is plain, single-quoted otherwise.
--- Codex hands the command to a shell; a bare path is what its own examples
--- use, so quotes are added only when they are needed.
local function sh(p)
  if p:find("[%s'\"\\$`]") then
    return "'" .. p:gsub("'", "'\\''") .. "'"
  end
  return p
end

local function toml(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- The command line the Codex entry carries.
function M.codex_command()
  return sh(M.nvim_path()) .. " -l " .. sh(M.hook_path()) .. " --agent codex"
end

--- Does any `[[hooks.<event>]]` block in a TOML text name our hook? A block
--- runs from its header to the next `[` header, and the same event can have
--- several blocks in the file (the inbox's first, ours after it).
function M.codex_has(text, event, hook)
  local pos = 1
  while true do
    local s, e = text:find("[[hooks." .. event .. "]]", pos, true)
    if not s then
      return false
    end
    local nxt = text:find("\n%[", e) or #text + 1
    if text:sub(e, nxt):find(hook, 1, true) then
      return true
    end
    pos = nxt
  end
end

--- Install into Codex's config.toml: one `[[hooks.UserPromptSubmit]]` and
--- one `[[hooks.Stop]]` block, appended. Codex rewrites this file itself, so
--- the blocks are appended, never merged, and the file is backed up first.
--- Idempotent by content: a block that names the hook path is present.
---@return string status, string file
function M.codex()
  local file = M.paths().codex
  local text = read(file) or ""
  local hook = M.hook_path()
  if text:find("agents/claude-code/hook.lua", 1, true) and not text:find(hook, 1, true) then
    error(file .. " already names a Lex hook at another path; edit that line by hand", 0)
  end
  local blocks = {}
  for _, event in ipairs(M.EVENTS) do
    if not M.codex_has(text, event, hook) then
      blocks[#blocks + 1] = ("[[hooks.%s]]\nhooks = [{ type = \"command\", command = \"%s\" }]\n"):format(event, toml(M.codex_command()))
    end
  end
  if #blocks == 0 then
    return "present", file
  end
  if text ~= "" then
    -- A backup that never overwrites an earlier one, even in the same second.
    local backup = file .. ".backup." .. os.date("%Y%m%d-%H%M%S")
    local k, name = 0, backup
    while vim.uv.fs_stat(name) do
      k = k + 1
      name = backup .. "-" .. k
    end
    write(name, text)
    if text:sub(-1) ~= "\n" then
      text = text .. "\n"
    end
    text = text .. "\n"
  end
  write(file, text .. table.concat(blocks, "\n"))
  return "installed", file
end

-- ── OpenCode ───────────────────────────────────────────────────────────────

--- Copy the plugin into OpenCode's plugin folder. A plugin is one file with
--- no imports of its own, so a copy is the whole install. Re-copied when the
--- source changed, which is how an update of lex.nvim reaches OpenCode.
---@return string status, string file
function M.opencode()
  local file = M.paths().opencode
  local src = read(M.opencode_source())
  if not src then
    error("no plugin source at " .. M.opencode_source(), 0)
  end
  local cur = read(file)
  if cur == src then
    return "present", file
  end
  write(file, src)
  return cur and "updated" or "installed", file
end

-- ── the dry run ────────────────────────────────────────────────────────────

--- Run the writer once, with the contract prompt, into a temporary store.
--- What `:checkhealth lex` reports, and a test of the whole exec path: this
--- nvim, this hook file, stdin, the store.
---@return { code: integer, stdout: string, stderr: string, records: integer, ms: number }
function M.dry_run()
  local tmp = vim.fn.tempname()
  local prompt = read(plugin_root() .. "/contract/prompt.txt") or ""
  local input = vim.json.encode({
    session_id = "dry-run",
    cwd = vim.fn.getcwd(),
    transcript_path = "",
    hook_event_name = "UserPromptSubmit",
    prompt = prompt,
  })
  local t0 = vim.uv.hrtime()
  local out = vim.system({ M.nvim_path(), "-l", M.hook_path() }, { stdin = input, text = true, env = { LEX_HOME = tmp } }):wait()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  local n = 0
  for _, f in ipairs(vim.fn.glob(tmp .. "/*/links.jsonl", false, true)) do
    for _ in io.lines(f) do
      n = n + 1
    end
  end
  vim.fn.delete(tmp, "rf")
  return { code = out.code, stdout = out.stdout or "", stderr = out.stderr or "", records = n, ms = ms }
end

-- ── the command ────────────────────────────────────────────────────────────

local NEXT = {
  claude = "Takes effect in the next Claude Code session.",
  codex = "Start codex once and press `t` when it says hooks need review; until then a new hook is installed but not active.",
  opencode = "Takes effect the next time OpenCode starts.",
}

--- `:LexInstallHook [claude|codex|opencode]`.
---@param agent? string
function M.run(agent)
  agent = (agent == nil or agent == "") and "claude" or agent
  local fn = agent == "claude" and M.claude or agent == "codex" and M.codex or agent == "opencode" and M.opencode
  if not fn then
    vim.notify("Lex: unknown agent " .. agent .. " (claude, codex, opencode)", vim.log.levels.ERROR)
    return
  end
  local ok, status, file = pcall(fn)
  if not ok then
    vim.notify("Lex: " .. tostring(status), vim.log.levels.ERROR)
    return
  end
  local said = ({ installed = "installed the hook in", updated = "updated the hook in", present = "the hook is already in" })[status]
  local msg = ("Lex: %s %s"):format(said, file)
  if status ~= "present" then
    msg = msg .. "\n" .. NEXT[agent]
  end
  vim.notify(msg, vim.log.levels.INFO)
end

return M
