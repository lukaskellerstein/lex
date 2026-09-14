-- Tests for lex.install. Run: nvim -l tests/install_test.lua
--
-- Every installer is pointed at a temporary directory through the agent's own
-- environment variable, so nothing here touches ~/.claude, ~/.codex or
-- ~/.config/opencode.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(_G.arg[0], ":p"))))
vim.opt.runtimepath:prepend(root)

local checks, failed = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
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

local tmp = vim.fn.tempname()
vim.env.CLAUDE_CONFIG_DIR = tmp .. "/claude"
vim.env.CODEX_HOME = tmp .. "/codex"
vim.env.XDG_CONFIG_HOME = tmp .. "/config"

local install = require("lex.install")
local json = require("lex.json")
local hook, nvim = install.hook_path(), install.nvim_path()

eq(vim.fn.filereadable(hook), 1, "hook_path: the file exists")
eq(hook:sub(1, #root), root, "hook_path: inside this checkout")
eq(vim.fn.executable(nvim), 1, "nvim_path: executable")
eq(install.paths(), {
  claude = tmp .. "/claude/settings.json",
  codex = tmp .. "/codex/config.toml",
  opencode = tmp .. "/config/opencode/plugin/lex.ts",
}, "paths: follow the agents' environment variables")

-- ── Claude Code ────────────────────────────────────────────────────────────

local settings = install.paths().claude

-- no settings file at all
eq({ install.claude() }, { "installed", settings }, "claude: fresh install")
local got = vim.json.decode(read(settings))
local entry = { hooks = { { type = "command", command = nvim, args = { "-l", hook }, timeout = 5 } } }
eq(got, { hooks = { UserPromptSubmit = { entry }, Stop = { entry }, SessionStart = { entry }, SessionEnd = { entry } } }, "claude: one entry per event, exec form")
eq({ install.claude() }, { "present", settings }, "claude: a second run finds it")

-- a file a person keeps: the entry is added, the rest stays as it was
local head = {
  "{",
  '  "$schema": "https://json.schemastore.org/claude-code-settings.json",',
  '  "permissions": {',
  '    "allow": [',
  '      "Read"',
  "    ],",
  '    "deny": []',
  "  },",
  '  "hooks": {',
  '    "UserPromptSubmit": [',
  "      {",
  '        "hooks": [',
  "          {",
  '            "type": "command",',
  '            "command": "\\"$HOME/.claude/hooks/inbox-state.sh\\" running"',
  "          }",
  "        ]",
  "      }",
}
local tail = {
  "    ],",
  '    "Stop": [',
  "      {",
  '        "hooks": [',
  "          {",
  '            "type": "command",',
  '            "command": "\\"$HOME/.claude/hooks/inbox-state.sh\\" done"',
  "          }",
  "        ]",
  "      }",
  "    ]",
  "  },",
  '  "model": "claude-fable-5-1[1m]"',
  "}",
  "",
}
-- our entry as one list item
local item = {
  "      {",
  '        "hooks": [',
  "          {",
  '            "type": "command",',
  '            "command": ' .. vim.json.encode(nvim) .. ",",
  '            "args": [',
  '              "-l",',
  "              " .. vim.json.encode(hook),
  "            ],",
  '            "timeout": 5',
  "          }",
  "        ]",
  "      }",
}
local function lines(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    vim.list_extend(out, part)
  end
  return table.concat(out, "\n")
end
local kept = lines(head, tail)
-- the same file with our item after the inbox item in UserPromptSubmit and
-- in Stop (the closing brace of the item before it gains a comma), and two
-- new lists, SessionStart and SessionEnd, after Stop
local expected = lines(
  vim.list_slice(head, 1, #head - 1),
  { "      }," },
  item,
  vim.list_slice(tail, 1, 9),
  { "      }," },
  item,
  { "    ],", '    "SessionStart": [' },
  item,
  { "    ],", '    "SessionEnd": [' },
  item,
  { "    ]" },
  vim.list_slice(tail, 12, #tail)
)
write(settings, kept)
eq({ install.claude() }, { "installed", settings }, "claude: install into a kept file")
local text = read(settings)
local obj = json.decode(text)
local keys = {}
for _, kv in ipairs(obj.pairs) do
  keys[#keys + 1] = kv[1]
end
eq(keys, { "$schema", "permissions", "hooks", "model" }, "claude: top-level key order kept")
local hook_keys = {}
for _, kv in ipairs(obj:get("hooks").pairs) do
  hook_keys[#hook_keys + 1] = kv[1]
end
eq(hook_keys, { "UserPromptSubmit", "Stop", "SessionStart", "SessionEnd" }, "claude: the kept events first, the new ones after")
local list = obj:get("hooks"):get("UserPromptSubmit")
eq(#list, 2, "claude: the inbox entry is still there")
eq(list[1]:get("hooks")[1]:get("command"), '"$HOME/.claude/hooks/inbox-state.sh" running', "claude: the inbox entry stays first")
eq(list[2]:get("hooks")[1]:get("args")[2], hook, "claude: ours is appended")
local stop = obj:get("hooks"):get("Stop")
eq(#stop, 2, "claude: ours is appended to Stop too")
eq(stop[1]:get("hooks")[1]:get("command"), '"$HOME/.claude/hooks/inbox-state.sh" done', "claude: the inbox Stop entry stays first")
eq(stop[2]:get("hooks")[1]:get("args")[2], hook, "claude: ours is second in Stop")
-- the file is the old file plus exactly the new entry
checks = checks + 1
if text ~= expected then
  failed = failed + 1
  print("FAIL claude: only the new entry was added\n" .. vim.diff(expected, text))
end
eq({ install.claude() }, { "present", settings }, "claude: idempotent on a kept file")
eq(read(settings), text, "claude: a present run writes nothing")

-- the plugin moved: the entry is updated in place
write(settings, (text:gsub(vim.pesc(root), "/old/checkout")))
eq({ install.claude() }, { "updated", settings }, "claude: an old path is updated")
obj = json.decode(read(settings))
list = obj:get("hooks"):get("UserPromptSubmit")
eq(#list, 2, "claude: no second entry after the update")
eq(list[2]:get("hooks")[1]:get("args")[2], hook, "claude: the path is current again")
eq(obj:get("hooks"):get("Stop")[2]:get("hooks")[1]:get("args")[2], hook, "claude: the Stop path is current again")
eq(#obj:get("hooks"):get("Stop"), 2, "claude: no second Stop entry either")
eq(#obj:get("hooks"):get("SessionStart"), 1, "claude: one SessionStart entry after the update")
eq(obj:get("hooks"):get("SessionEnd")[1]:get("hooks")[1]:get("args")[2], hook, "claude: the SessionEnd path is current again")

-- a settings file that is not an object
write(settings, "[1, 2]\n")
eq(pcall(install.claude), false, "claude: a non-object raises, the file is left alone")
eq(read(settings), "[1, 2]\n", "claude: the bad file is untouched")

-- ── Codex ──────────────────────────────────────────────────────────────────

local config = install.paths().codex
local function cblock(event)
  local timeout = event == "SessionEnd" and 3 or 5
  return ('[[hooks.%s]]\n\n[[hooks.%s.hooks]]\ntype = "command"\ncommand = "%s -l %s --agent codex"\ntimeout = %d\n'):format(event, event, nvim, hook, timeout)
end
local function cblocks(events)
  local out = {}
  for _, e in ipairs(events) do
    out[#out + 1] = cblock(e)
  end
  return table.concat(out, "\n")
end
local ALL = { "UserPromptSubmit", "Stop", "SessionStart", "SessionEnd" }
eq({ install.codex() }, { "installed", config }, "codex: fresh install")
text = read(config)
eq(text, cblocks(ALL), "codex: four blocks, bare paths")
eq({ install.codex() }, { "present", config }, "codex: a second run finds all four")
eq(read(config), text, "codex: a present run writes nothing")

local existing = 'model = "gpt-5"\n\n[[hooks.UserPromptSubmit]]\nhooks = [{ type = "command", command = "/x/inbox-state.sh running prompt" }]\n\n[hooks.state]\n'
write(config, existing)
eq({ install.codex() }, { "installed", config }, "codex: append to a kept file")
text = read(config)
eq(text:sub(1, #existing), existing, "codex: the kept file is a prefix")
eq(text:sub(#existing + 1), "\n" .. cblocks(ALL), "codex: the blocks follow a blank line")
local backups = vim.fn.glob(config .. ".backup.*", false, true)
eq(#backups, 1, "codex: one backup of a kept file")
eq(read(backups[1]), existing, "codex: the backup is the old file")

-- a config from before the session hooks existed: only the missing blocks
write(config, cblocks({ "UserPromptSubmit", "Stop" }))
eq({ install.codex() }, { "installed", config }, "codex: an older config gets the session blocks")
eq(read(config), cblocks(ALL), "codex: only the missing blocks were appended")
eq({ install.codex() }, { "present", config }, "codex: then present")
eq(#vim.fn.glob(config .. ".backup.*", false, true), 2, "codex: a second backup in the same second keeps the first")

-- The installer still recognizes its pre-0.2 inline-array form, so upgrading
-- does not create duplicate handlers.
local legacy_codex = cblocks({ "Stop", "SessionStart", "SessionEnd" })
  .. ('\n[[hooks.UserPromptSubmit]]\nhooks = [{ type = "command", command = "%s -l %s --agent codex" }]\n'):format(nvim, hook)
write(config, legacy_codex)
eq({ install.codex() }, { "present", config }, "codex: a legacy inline entry is recognized")
eq(read(config), legacy_codex, "codex: recognizing legacy syntax writes nothing")

write(config, 'model = "gpt-5"')
install.codex()
eq(read(config):sub(#'model = "gpt-5"' + 1, #'model = "gpt-5"' + 2), "\n\n", "codex: a missing final newline is added first")

write(config, '[[hooks.UserPromptSubmit]]\nhooks = [{ type = "command", command = "/old/agents/claude-code/hook.lua" }]\n')
eq(pcall(install.codex), false, "codex: another checkout's entry raises")

eq(install.codex_command(), nvim .. " -l " .. hook .. " --agent codex", "codex: the command line")

-- ── OpenCode ───────────────────────────────────────────────────────────────

local plugin = install.paths().opencode
eq({ install.opencode() }, { "installed", plugin }, "opencode: fresh install")
eq(read(plugin), read(install.opencode_source()), "opencode: a copy of the source")
eq({ install.opencode() }, { "present", plugin }, "opencode: a second run finds it")
write(plugin, "// stale\n")
eq({ install.opencode() }, { "updated", plugin }, "opencode: a changed file is re-copied")
eq(read(plugin), read(install.opencode_source()), "opencode: current again")

-- ── the dry run ────────────────────────────────────────────────────────────

local r = install.dry_run()
eq({ r.code, r.records, r.stdout, r.stderr }, { 0, 5, "", "" }, "dry_run: five records, silent")
io.stdout:write(("  dry run: %.0f ms\n"):format(r.ms))

vim.fn.delete(tmp, "rf")
io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
