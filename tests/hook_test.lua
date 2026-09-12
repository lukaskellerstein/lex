-- Tests for agents/claude-code/hook.lua and lex.store. Run: nvim -l tests/hook_test.lua
--
-- The hook is run the way Claude Code runs it: a child `nvim -l`, the JSON on
-- stdin, the environment carrying $LEX_HOME and $TMUX_PANE. The records are
-- compared with contract/records.json.

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
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local nvim = vim.fn.exepath("nvim") ~= "" and vim.fn.exepath("nvim") or vim.v.progpath
local hook = root .. "/agents/claude-code/hook.lua"
local prompt = read(root .. "/contract/prompt.txt")
local want = vim.json.decode(read(root .. "/contract/records.json"))
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local SESSION = {
  session_id = "f357503d-15a0-4f23-b026-7f45ddff59c3",
  transcript_path = "/Users/lukas/.claude/projects/-Users-lukas-Projects-aaa/f357503d.jsonl",
  cwd = "/Users/lukas/Projects/aaa/.worktrees/lukas-44",
  prompt_id = "cf181020-c211-4449-a1f4-0f172242d708",
  permission_mode = "default",
  hook_event_name = "UserPromptSubmit",
}

local function run(home, stdin, args, env)
  local cmd = { nvim, "-l", hook }
  vim.list_extend(cmd, args or {})
  local e = { LEX_HOME = home, TMUX_PANE = "%212" }
  for k, v in pairs(env or {}) do
    e[k] = v
  end
  local t0 = vim.uv.hrtime()
  local out = vim.system(cmd, { stdin = stdin, text = true, env = e }):wait()
  out.ms = (vim.uv.hrtime() - t0) / 1e6
  return out
end

local function records(home)
  local all = {}
  for _, file in ipairs(vim.fn.glob(home .. "/*/links.jsonl", false, true)) do
    for line in io.lines(file) do
      all[#all + 1] = vim.json.decode(line)
    end
  end
  table.sort(all, function(a, b)
    if a.repo ~= b.repo then
      return a.repo < b.repo
    end
    return a.index < b.index
  end)
  return all
end

local SESSION_FIELDS = { "at", "agent", "session", "pid", "pane", "transcript", "cwd" }
local function place_part(r)
  local p = vim.deepcopy(r)
  for _, k in ipairs(SESSION_FIELDS) do
    p[k] = nil
  end
  return p
end

local function input(fields)
  return vim.json.encode(vim.tbl_extend("force", SESSION, fields))
end

-- the contract prompt, as Claude Code
local home = tmp .. "/claude"
local out = run(home, input({ prompt = prompt }))
eq(out.code, 0, "claude: exit 0")
eq(out.stdout, "", "claude: nothing on stdout")
eq(out.stderr, "", "claude: nothing on stderr")
eq(vim.fn.filereadable(home .. "/hook.log"), 0, "claude: no hook.log")
local got = records(home)
eq(#got, 5, "claude: five records")
local places = {}
for _, r in ipairs(got) do
  places[#places + 1] = place_part(r)
end
eq(places, want, "claude: the records match contract/records.json")
for i, r in ipairs(got) do
  eq(r.agent, "claude", ("claude: record %d agent"):format(i))
  eq(r.session, SESSION.session_id, ("claude: record %d session"):format(i))
  eq(r.transcript, SESSION.transcript_path, ("claude: record %d transcript"):format(i))
  eq(r.cwd, SESSION.cwd, ("claude: record %d cwd"):format(i))
  eq(r.pane, "%212", ("claude: record %d pane"):format(i))
  eq(type(r.pid) == "number" and r.pid > 0, true, ("claude: record %d pid"):format(i))
  eq(type(r.at) == "number" and math.abs(r.at - os.time()) < 60, true, ("claude: record %d at"):format(i))
end
local dirs = vim.fn.glob(home .. "/*", false, true)
table.sort(dirs)
eq(vim.tbl_map(vim.fs.basename, dirs), { "-Users-lukas-Projects-aaa", "-Users-lukas-Projects-other", "sessions" }, "claude: one folder per repository, slugged, plus the sessions folder")
io.stdout:write(("  the hook took %.0f ms\n"):format(out.ms))
if out.ms > 100 then
  io.stdout:write("  WARN slower than the 50 ms budget\n")
end

-- the same, as Codex
home = tmp .. "/codex"
out = run(home, input({ prompt = prompt, turn_id = "t1" }), { "--agent", "codex" })
eq(out.code, 0, "codex: exit 0")
got = records(home)
eq(#got, 5, "codex: five records")
eq(got[1].agent, "codex", "codex: the agent field")

-- a second prompt appends; the store keeps history
run(home, input({ prompt = prompt }), { "--agent", "codex" })
eq(#records(home), 10, "codex: a second prompt appends five more")

-- the store reader
vim.env.LEX_HOME = home
local store = require("lex.store")
eq(store.slug("/Users/lukas/Projects/aaa/.worktrees/x_1"), "-Users-lukas-Projects-aaa--worktrees-x-1", "store: the slug rule")
eq(store.file("/a/b"), home .. "/-a-b/links.jsonl", "store: the file for a repo")
eq(#store.read("/Users/lukas/Projects/aaa"), 8, "store: read one repository")
eq(#store.read("/Users/lukas/Projects/other"), 2, "store: read the other")
eq(store.read("/nowhere"), {}, "store: an unknown repo is empty")
eq(store.repos(), { { slug = "-Users-lukas-Projects-aaa", count = 8 }, { slug = "-Users-lukas-Projects-other", count = 2 } }, "store: repos()")
local f = assert(io.open(store.file("/Users/lukas/Projects/other"), "a"))
f:write("{not json\n")
f:close()
eq(#store.read("/Users/lukas/Projects/other"), 2, "store: a bad line is skipped")
vim.env.LEX_HOME = nil

-- outside tmux: no pane
home = tmp .. "/nopane"
run(home, input({ prompt = prompt }), nil, { TMUX_PANE = "" })
eq(records(home)[1].pane, nil, "no tmux: pane absent")

-- the session state: working on a prompt, idle on Stop
local function state_of(h, id)
  local f = io.open(h .. "/sessions/" .. id .. ".json", "r")
  if not f then
    return nil
  end
  local s = vim.json.decode(f:read("*a"))
  f:close()
  return s
end
local st = state_of(tmp .. "/claude", SESSION.session_id)
eq({ st.state, st.agent, st.pane, st.cwd, type(st.pid), type(st.at) }, { "working", "claude", "%212", SESSION.cwd, "number", "number" }, "state: working after the prompt")
out = run(tmp .. "/claude", vim.json.encode({ session_id = SESSION.session_id, transcript_path = SESSION.transcript_path, cwd = SESSION.cwd, hook_event_name = "Stop", stop_hook_active = false }))
eq(out.code, 0, "stop: exit 0")
eq(state_of(tmp .. "/claude", SESSION.session_id).state, "idle", "state: idle after Stop")
eq(#records(tmp .. "/claude"), 5, "stop: no record written")
eq(state_of(tmp .. "/codex", SESSION.session_id).agent, "codex", "state: the codex writer names itself")
local function event(name, extra)
  return vim.json.encode(vim.tbl_extend("force", { session_id = SESSION.session_id, transcript_path = SESSION.transcript_path, cwd = SESSION.cwd, hook_event_name = name }, extra or {}))
end
out = run(tmp .. "/claude", event("SessionStart", { source = "resume" }))
eq(out.code, 0, "session start: exit 0")
st = state_of(tmp .. "/claude", SESSION.session_id)
eq({ st.state, st.pane, type(st.pid) }, { "idle", "%212", "number" }, "state: idle with the new pid and pane after a resume")
run(tmp .. "/claude", input({ prompt = "again" }))
eq(state_of(tmp .. "/claude", SESSION.session_id).state, "working", "state: working again")
run(tmp .. "/claude", event("SessionStart", { source = "compact" }))
eq(state_of(tmp .. "/claude", SESSION.session_id).state, "working", "state: a compaction changes nothing")
out = run(tmp .. "/claude", event("SessionEnd", { reason = "exit" }))
eq(out.code, 0, "session end: exit 0")
eq(state_of(tmp .. "/claude", SESSION.session_id).state, "ended", "state: ended after SessionEnd")
run(tmp .. "/claude", event("PostToolUse"))
eq(state_of(tmp .. "/claude", SESSION.session_id).state, "ended", "state: an unknown event changes nothing")
eq(#records(tmp .. "/claude"), 5, "events: no event wrote a record, and a prompt with no block writes none either")

-- nothing to do: no places, garbage, empty
home = tmp .. "/none"
out = run(home, input({ prompt = "just a question" }))
eq(out.code, 0, "no places: exit 0")
eq(#vim.fn.glob(home .. "/*/links.jsonl", false, true), 0, "no places: no links written")
eq(state_of(home, SESSION.session_id).state, "working", "no places: the state is still written")
home = tmp .. "/garbage"
out = run(home, "not json at all")
eq(out.code, 0, "garbage: exit 0")
eq(out.stdout, "", "garbage: nothing on stdout")
eq(vim.fn.isdirectory(home), 0, "garbage: nothing written")
out = run(home, "")
eq(out.code, 0, "empty stdin: exit 0")
out = run(home, '{"prompt": 5}')
eq(out.code, 0, "a prompt that is not a string: exit 0")
eq(vim.fn.isdirectory(home), 0, "a prompt that is not a string: nothing written")
out = run(home, '{"session_id": "../evil", "prompt": "x"}')
eq(vim.fn.isdirectory(home), 0, "a session id with a slash writes nothing")

-- blocks only: the prompt line is empty
home = tmp .. "/blocks"
run(home, input({ prompt = '<lex-place path="/r/x.ts" repo="/r" file="x.ts"/>\n\n' }))
got = records(home)
eq(#got, 1, "blocks only: one record")
eq(got[1].prompt, "", "blocks only: an empty prompt line")

-- the caps: 200 code points, not bytes
home = tmp .. "/caps"
local long = ("é"):rep(300)
run(home, input({ prompt = ('<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\n  %s  \n</lex-place>\n%s'):format(long, long) }))
got = records(home)
eq(vim.fn.strchars(got[1].head), 200, "cap: head is 200 characters")
eq(vim.fn.strchars(got[1].prompt), 200, "cap: prompt is 200 characters")
eq(got[1].hash, nil == nil and got[1].hash, "cap: hash present")

-- before/after: read from the file when it still says what the body says
home = tmp .. "/ctx"
local ctx = tmp .. "/ctxrepo"
vim.fn.mkdir(ctx, "p")
local ten = {}
for i = 1, 10 do
  ten[i] = ("line%d"):format(i)
end
vim.fn.writefile(ten, ctx .. "/file.lua")
vim.fn.writefile(ten, ctx .. "/crlf.lua", "b")
vim.fn.writefile(vim.tbl_map(function(l)
  return l .. "\r"
end, ten), ctx .. "/crlf.lua")
local function block(file, from, to, body)
  return ('<lex-place path="%s/%s" repo="%s" file="%s" lines="%d-%d">\n%s\n</lex-place>'):format(ctx, file, ctx, file, from, to, body)
end
run(home, input({ prompt = table.concat({
  block("file.lua", 4, 6, "line4\nline5\nline6"),
  block("file.lua", 1, 2, "line1\nline2"),
  block("file.lua", 9, 10, "line9\nline10"),
  block("file.lua", 4, 6, "changed"),
  block("crlf.lua", 4, 6, "line4\nline5\nline6"),
  block("missing.lua", 4, 6, "line4\nline5\nline6"),
  "why?",
}, "\n") }))
got = records(home)
eq(#got, 6, "context: six records")
eq({ got[1].body, got[1].before, got[1].after }, { "line4\nline5\nline6", "line2\nline3", "line7\nline8" }, "context: middle of the file")
eq({ got[2].before, got[2].after }, { nil, "line3\nline4" }, "context: at the top, no before")
eq({ got[3].before, got[3].after }, { "line7\nline8", nil }, "context: at the end, no after")
eq({ got[4].body, got[4].before, got[4].after }, { "changed", nil, nil }, "context: the file moved on, body kept, no context")
eq({ got[5].before, got[5].after }, { "line2\nline3", "line7\nline8" }, "context: a CRLF file still matches")
eq({ got[6].body, got[6].before, got[6].after }, { "line4\nline5\nline6", nil, nil }, "context: a missing file, body kept, no context")

-- the hash vectors, through the whole path
home = tmp .. "/fnv"
run(home, input({ prompt = table.concat({
  '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\na\n</lex-place>',
  '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\nfoo bar\n</lex-place>',
  '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-2">\n \n\t\n</lex-place>',
}, "\n") }))
got = records(home)
eq({ got[1].hash, got[2].hash, got[3].hash }, { "e40c292c", "bf9cf968", "811c9dc5" }, "fnv: a, foobar (whitespace removed), empty")
eq({ got[3].head, got[3].tail }, { nil, nil }, "fnv: a blank body has no head and no tail")

vim.fn.delete(tmp, "rf")
io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
