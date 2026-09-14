-- lex.open: back into the conversation. What `<CR>` in the picker does.
--
--   gone       the transcript was deleted: nothing to open, say so.
--   running    `lex.locate` proves where the session is, right now, from a
--              live process: the state file, the command line of a resume,
--              or the process holding its session file. The tmux pane comes
--              from that process's own place in the tree, never from the
--              record: a stored pane goes stale and then takes you to
--              somebody else's conversation (seen 2026-09-12).
--              `config.opener` gets the id, the pid and the proved pane and
--              may do better than tmux (mac-setup: `lukas-inbox jump`,
--              which also focuses the desktop and the window, and can find
--              a window with no tmux at all by its pid). Then tmux:
--              select-window, select-pane, and switch-client when nvim runs
--              inside tmux.
--   not found  resume it. You choose where: a new terminal window first,
--              then a new window in one of your tmux sessions (the current
--              one first). The new window runs the agent's resume command
--              in the session's own folder, and the same jump takes you
--              there.
--
-- The commands live in `config.agents`, so a fourth agent is one entry.
-- Nothing here writes to the store.

local links = require("lex.links")

local M = {}

local function notify(msg, level)
  vim.notify("Lex: " .. msg, level or vim.log.levels.INFO)
end

local function tmux(args)
  if vim.fn.executable("tmux") ~= 1 then
    return false, "", "tmux is not installed"
  end
  local cmd = { "tmux" }
  vim.list_extend(cmd, args)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then
    return false, "", tostring(proc)
  end
  local waited, out = pcall(function()
    return proc:wait()
  end)
  if not waited then
    return false, "", tostring(out)
  end
  return out.code == 0, vim.trim(out.stdout or ""), vim.trim(out.stderr or "")
end

local function inside_tmux()
  local t = os.getenv("TMUX")
  return t ~= nil and t ~= ""
end

--- A short session id for a title: the first 8 characters.
local function short(id)
  return (tostring(id):gsub("^ses_", "")):sub(1, 8)
end

-- ── the jump ───────────────────────────────────────────────────────────────

---@class lex.Target
---@field session? string   the agent's session id
---@field agent? string
---@field pid? integer
---@field pane? string

--- The machine's own way to a session, when the config has one.
---@param t lex.Target
---@return boolean
local function via_opener(t)
  local opener = require("lex").config.opener
  if not opener then
    return false
  end
  local ok, res = pcall(opener, t)
  return ok and res == true
end

--- Focus the session's tmux pane. The opener first; then tmux, which can
--- select the window and pane anywhere, and switch this client only when
--- nvim itself runs inside tmux. Returns whether something was focused.
---@param t lex.Target
---@return boolean
function M.jump(t)
  if via_opener(t) then
    return true
  end
  if not t.pane then
    return false
  end
  local ok, session = tmux({ "display-message", "-p", "-t", t.pane, "#{session_name}" })
  if not ok then
    return false
  end
  tmux({ "select-window", "-t", t.pane })
  tmux({ "select-pane", "-t", t.pane })
  if inside_tmux() then
    tmux({ "switch-client", "-t", session })
  else
    notify(("showing it in tmux session %s; that terminal is yours to focus"):format(session))
  end
  return true
end

-- ── a new terminal window ──────────────────────────────────────────────────

--- The terminals Lex knows how to open a window in, in the order they are
--- tried. `config.terminal` overrides: the name of one of them ("kitty"),
--- a function(cmd, dir, title) that returns true when it opened one, or
--- `false` to leave the entry out.
---
--- The child gets an environment without `TMUX` and `TMUX_PANE`: a terminal
--- started from inside tmux would otherwise believe every tab of its own is
--- inside somebody else's tmux (mac-setup learned this with Ghostty).
---@type { name: string, available: fun(): string|nil, argv: fun(bin: string, cmd: string[], dir: string, title: string): string[] }[]
M.terminals = {
  {
    name = "Ghostty",
    available = function()
      local app = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
      if vim.uv.fs_stat(app) then
        return app
      end
      return vim.fn.executable("ghostty") == 1 and "ghostty" or nil
    end,
    argv = function(bin, cmd, dir, title)
      local out = { bin, "--working-directory=" .. dir, "--title=" .. title, "-e" }
      return vim.list_extend(out, cmd)
    end,
  },
  {
    name = "WezTerm",
    available = function()
      return vim.fn.executable("wezterm") == 1 and "wezterm" or nil
    end,
    argv = function(bin, cmd, dir)
      local out = { bin, "start", "--cwd", dir, "--" }
      return vim.list_extend(out, cmd)
    end,
  },
  {
    name = "kitty",
    available = function()
      return vim.fn.executable("kitty") == 1 and "kitty" or nil
    end,
    argv = function(bin, cmd, dir, title)
      local out = { bin, "--directory", dir, "--title", title }
      return vim.list_extend(out, cmd)
    end,
  },
  {
    name = "Alacritty",
    available = function()
      return vim.fn.executable("alacritty") == 1 and "alacritty" or nil
    end,
    argv = function(bin, cmd, dir, title)
      local out = { bin, "--working-directory", dir, "--title", title, "-e" }
      return vim.list_extend(out, cmd)
    end,
  },
  {
    name = "$TERMINAL",
    available = function()
      local t = os.getenv("TERMINAL")
      return (t and t ~= "" and vim.fn.executable(t) == 1) and t or nil
    end,
    argv = function(bin, cmd, dir)
      local words = {}
      for _, w in ipairs(cmd) do
        words[#words + 1] = vim.fn.shellescape(w)
      end
      return { bin, "-e", "sh", "-c", "cd " .. vim.fn.shellescape(dir) .. " && exec " .. table.concat(words, " ") }
    end,
  },
  {
    name = "Terminal.app",
    available = function()
      return (vim.uv.os_uname().sysname == "Darwin" and vim.fn.executable("osascript") == 1) and "osascript" or nil
    end,
    argv = function(bin, cmd, dir)
      local words = {}
      for _, w in ipairs(cmd) do
        words[#words + 1] = vim.fn.shellescape(w)
      end
      local line = ("cd %s && %s"):format(vim.fn.shellescape(dir), table.concat(words, " "))
      local script = ('tell application "Terminal" to do script "%s"'):format(line:gsub('[\\"]', "\\%0"))
      return { bin, "-e", script, "-e", 'tell application "Terminal" to activate' }
    end,
  },
}

--- The terminal to use: the configured name, else the first one on this
--- machine, or nil.
---@return { name: string, bin: string, argv: function }|nil
function M.detect_terminal()
  local want = require("lex").config.terminal
  for _, t in ipairs(M.terminals) do
    if type(want) ~= "string" or t.name:lower() == want:lower() then
      local bin = t.available()
      if bin then
        return { name = t.name, bin = bin, argv = t.argv }
      end
    end
  end
  return nil
end

--- Open a new terminal window running the command. Returns whether it did.
---@param cmd string[]
---@param dir string
---@param title string
---@return boolean
function M.new_terminal(cmd, dir, title)
  local custom = require("lex").config.terminal
  if type(custom) == "function" then
    return custom(cmd, dir, title) and true or false
  end
  local t = M.detect_terminal()
  if not t then
    return false
  end
  local env = vim.fn.environ()
  env.TMUX, env.TMUX_PANE = nil, nil
  local ok = pcall(vim.system, t.argv(t.bin, cmd, dir, title), { env = env, clear_env = true, detach = true })
  return ok
end

-- ── where to resume ────────────────────────────────────────────────────────

---@class lex.Choice
---@field label string
---@field session? string   a tmux session name
---@field terminal? boolean a new terminal window

--- The tmux sessions from `list-sessions` output, one per line:
--- name, window count, attached (0/1), last attached (unix seconds).
--- The current session first, then attached ones, then the most recently
--- attached. Pure, for the test.
---@param text string
---@param current? string
---@return lex.Choice[]
function M.parse_sessions(text, current)
  local rows = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name, windows, attached, last = line:match("^(.-)\t(%d+)\t(%d+)\t(%d*)$")
    if name then
      rows[#rows + 1] = { name = name, windows = tonumber(windows), attached = attached ~= "0", last = tonumber(last) or 0 }
    end
  end
  table.sort(rows, function(a, b)
    if (a.name == current) ~= (b.name == current) then
      return a.name == current
    end
    if a.attached ~= b.attached then
      return a.attached
    end
    return a.last > b.last
  end)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = {
      label = ("tmux %s  ·  %d window%s%s%s"):format(r.name, r.windows, r.windows == 1 and "" or "s", r.attached and ", attached" or "", r.name == current and ", this one" or ""),
      session = r.name,
    }
  end
  return out
end

--- The places a session can be resumed in, on this machine, now: a new
--- terminal window first, when one can be opened, then the tmux sessions.
---@return lex.Choice[]
function M.targets()
  local out = {}
  local custom = require("lex").config.terminal
  if type(custom) == "function" or (custom ~= false and M.detect_terminal()) then
    out[#out + 1] = { label = "new terminal", terminal = true }
  end
  local ok, text = tmux({ "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_last_attached}" })
  if ok then
    local current
    if inside_tmux() then
      local ok2, name = tmux({ "display-message", "-p", "#{session_name}" })
      current = ok2 and name or nil
    end
    vim.list_extend(out, M.parse_sessions(text, current))
  end
  return out
end

--- The resume command and folder for a record.
---@param rec lex.Record
---@return string[]|nil cmd, string dir, table|nil agent
local function resume_command(rec)
  local cfg = require("lex").config
  local agent = cfg.agents[rec.agent]
  if not agent then
    return nil, rec.repo, nil
  end
  local cmd = vim.deepcopy(agent.resume)
  cmd[#cmd + 1] = rec.session
  local dir = (rec.cwd and vim.fn.isdirectory(rec.cwd) == 1) and rec.cwd or rec.repo
  return cmd, dir, agent
end

--- A new tmux window in a session, running the command; returns its pane id.
---@return string|nil pane, string|nil err
local function new_window(session, cmd, dir, name)
  local words = {}
  for _, w in ipairs(cmd) do
    words[#words + 1] = vim.fn.shellescape(w)
  end
  local ok, pane, err = tmux({ "new-window", "-P", "-F", "#{pane_id}", "-t", session .. ":", "-c", dir, "-n", name, table.concat(words, " ") })
  if not ok then
    return nil, err
  end
  return pane
end

--- Resume a session where the user says.
---@param rec lex.Record
---@param why? string what happened before, shown in the prompt
function M.resume(rec, why)
  local cmd, dir, agent = resume_command(rec)
  if not cmd then
    return notify("no resume command for agent " .. tostring(rec.agent), vim.log.levels.WARN)
  end
  local targets = M.targets()
  if #targets == 0 then
    return notify("no terminal and no tmux to resume in; set `terminal` in the Lex config", vim.log.levels.ERROR)
  end
  local id = short(rec.session)
  local prompt = ("%sResume %s session %s in:"):format(why and (why .. ". ") or "", agent.name, id)
  vim.ui.select(targets, {
    prompt = prompt,
    format_item = function(t)
      return t.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.terminal then
      if not M.new_terminal(cmd, dir, id) then
        notify("could not open a terminal window; set `terminal` in the Lex config", vim.log.levels.ERROR)
      end
      return
    end
    -- The window is named after the session, the same eight characters the
    -- prompt shows, so a row of tabs says which conversation is which.
    local pane, err = new_window(choice.session, cmd, dir, id)
    if not pane then
      return notify("tmux could not open a window: " .. tostring(err), vim.log.levels.ERROR)
    end
    if not M.jump({ session = rec.session, agent = rec.agent, pane = pane }) then
      notify(("opened in tmux session %s, window %s"):format(choice.session, pane))
    end
  end)
end

--- Open a record's conversation the right way for its state.
---@param rec lex.Record
function M.open(rec)
  if links.gone(rec) then
    return notify("the transcript of this session was deleted; nothing to open", vim.log.levels.WARN)
  end
  -- Fresh, never the picker's snapshot: a row may have been on screen for
  -- a while, and the session can have moved or ended since it was drawn.
  local loc = require("lex.locate").locate(rec)
  local target = { session = rec.session, agent = rec.agent, pid = loc and loc.pid, pane = loc and loc.pane }
  -- The machine's own way first. It gets a pane only when a live process
  -- proved it, so it can never be sent to a pane somebody else took over.
  if via_opener(target) then
    return
  end
  if loc then
    if M.jump(target) then
      return
    end
    local where = loc.pane and ("pane " .. loc.pane) or "a window outside tmux"
    return M.resume(rec, ("the session runs at pid %d in %s, which is not reachable from here"):format(loc.pid, where))
  end
  M.resume(rec)
end

return M
