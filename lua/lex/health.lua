-- :checkhealth lex
--
-- The nvim the hook names, the hook file, each agent's entry, the store, and
-- one dry run of the writer with the contract prompt, timed.

local M = {}

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

function M.check()
  local health = vim.health
  local install = require("lex.install")
  local store = require("lex.store")
  local paths = install.paths()
  local nvim, hook = install.nvim_path(), install.hook_path()

  health.start("lex: the writer")
  if vim.fn.executable(nvim) == 1 then
    health.ok("nvim: " .. nvim)
  else
    health.error("nvim not found: " .. nvim, "The hook entry needs an absolute path to an nvim that exists.")
  end
  if vim.fn.filereadable(hook) == 1 then
    health.ok("hook: " .. hook)
  else
    health.error("hook file missing: " .. hook)
  end

  health.start("lex: Claude Code")
  local text = read(paths.claude)
  if not text then
    health.warn("no " .. paths.claude, "Run :LexInstallHook")
  else
    local ok, root = pcall(vim.json.decode, text)
    if not ok then
      health.error(paths.claude .. " does not parse: " .. tostring(root))
    else
      for _, event in ipairs(install.EVENTS) do
        local found, exact = false, false
        if type(root) == "table" and type(root.hooks) == "table" then
          for _, entry in ipairs(root.hooks[event] or {}) do
            for _, h in ipairs(entry.hooks or {}) do
              local script = type(h.args) == "table" and h.args[2]
              if type(script) == "string" and script:match("agents/claude%-code/hook%.lua$") then
                found = true
                exact = h.command == nvim and script == hook
              end
            end
          end
        end
        if exact then
          health.ok(event .. " entry in " .. paths.claude)
        elseif found then
          health.warn("the " .. event .. " entry in " .. paths.claude .. " points at another nvim or another checkout", "Run :LexInstallHook to update it")
        else
          health.warn("no " .. event .. " entry in " .. paths.claude, "Run :LexInstallHook")
        end
      end
    end
  end

  health.start("lex: Codex")
  text = read(paths.codex)
  if not text then
    health.info("no " .. paths.codex .. " (Codex not set up on this machine)")
  else
    for _, event in ipairs(install.EVENTS) do
      if install.codex_has(text, event, hook) then
        health.ok(event .. " entry in " .. paths.codex)
      elseif install.codex_has(text, event, "agents/claude-code/hook.lua") then
        health.warn("the " .. event .. " entry in " .. paths.codex .. " points at another checkout", "Edit that line by hand")
      else
        health.warn("no " .. event .. " entry in " .. paths.codex, "Run :LexInstallHook codex")
      end
    end
    health.info("if /hooks in the Codex TUI shows a hook as not active, press `t` there to trust it")
  end

  health.start("lex: OpenCode")
  local cur, src = read(paths.opencode), read(install.opencode_source())
  if cur and cur == src then
    health.ok("plugin at " .. paths.opencode)
  elseif cur then
    health.warn("plugin at " .. paths.opencode .. " differs from the source", "Run :LexInstallHook opencode")
  elseif vim.fn.isdirectory(vim.fs.dirname(vim.fs.dirname(paths.opencode))) == 1 then
    health.warn("no plugin at " .. paths.opencode, "Run :LexInstallHook opencode")
  else
    health.info("no " .. vim.fs.dirname(vim.fs.dirname(paths.opencode)) .. " (OpenCode not set up on this machine)")
  end

  health.start("lex: the store")
  local home = store.home()
  if vim.fn.isdirectory(home) == 1 then
    local repos, total = store.repos(), 0
    for _, r in ipairs(repos) do
      total = total + r.count
    end
    health.ok(("%s: %d repositories, %d links"):format(home, #repos, total))
    local sessions, working, ended = 0, 0, 0
    for name in vim.fs.dir(home .. "/sessions") do
      sessions = sessions + 1
      local st = read(home .. "/sessions/" .. name)
      if st and st:find('"working"', 1, true) then
        working = working + 1
      elseif st and st:find('"ended"', 1, true) then
        ended = ended + 1
      end
    end
    health.info(("%d session state files: %d working, %d ended, %d idle"):format(sessions, working, ended, sessions - working - ended))
    local log = read(home .. "/hook.log")
    if log and log ~= "" then
      local n = select(2, log:gsub("\n", ""))
      health.warn(("%d lines in %s/hook.log"):format(n, home), "The writer hit an error; the last line says what.")
    end
  else
    health.info(home .. " does not exist yet; the first prompt with a place creates it")
  end

  health.start("lex: a dry run")
  local ok, r = pcall(install.dry_run)
  if not ok then
    health.error("could not run the hook: " .. tostring(r))
  elseif r.code == 0 and r.records == 5 and r.stdout == "" then
    health.ok(("the hook wrote 5 records from the contract prompt in %.0f ms"):format(r.ms))
  else
    health.error(("the hook returned %d with %d records (want 5); stdout %q; stderr %q"):format(r.code, r.records, r.stdout, r.stderr))
  end
end

return M
