-- Tests for lex.locate. Run: nvim -l tests/locate_test.lua
--
-- The parsing and the walk are pure and take their input as text, so the
-- cases below are the real shapes `ps` and `tmux` print on this machine.
-- The one live check starts a real process and finds it by its arguments.

vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(_G.arg[0], ":p")))))

local locate = require("lex.locate")
local checks, failed = 0, 0

local function eq(got, want, what)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

-- `ps -axww -o pid=,ppid=,command=`, as macOS prints it: leading spaces,
-- and a command line that holds spaces and its own flags.
local PS = table.concat({
  "    1     0 /sbin/launchd",
  "19936     1 tmux",
  "42011 19936 -zsh",
  "47658 19936 claude --resume 16456e05-f164-4e0b-acee-dd556b9b8086",
  "18404 71138 /Applications/Ghostty.app/Contents/MacOS/ghostty --title=f6d42da6 -e opencode -s ses_f6d42da6",
  "18410 18404 /usr/bin/login -q -flp lukas opencode -s ses_f6d42da6",
  "18441 18410 opencode -s ses_f6d42da6",
  "81384 19936 node",
  "43938 81384 codex resume 01a092bb-e050-7ff2-9197-08192f3ec240",
  "garbage",
}, "\n")
local PANES = table.concat({
  "42011 %332",
  "19936 %1",
  "81384 %346",
  "20689 %2",
  "nonsense",
}, "\n")

local procs = locate.processes(PS)
local panes = locate.panes(PANES)
eq(vim.tbl_count(procs), 9, "processes: nine lines parsed, the garbage skipped")
eq(procs[47658], { pid = 47658, ppid = 19936, cmd = "claude --resume 16456e05-f164-4e0b-acee-dd556b9b8086" }, "processes: a full command line")
eq(procs[18404].cmd:find("--title=f6d42da6", 1, true) ~= nil, true, "processes: a long command line is not cut")
eq(vim.tbl_count(panes), 4, "panes: four, the nonsense skipped")
eq(panes[81384], "%346", "panes: a pane by its process")

-- the walk to a pane
eq(locate.pane_of(43938, procs, panes), "%346", "pane_of: the agent's parent is the pane's process")
eq(locate.pane_of(81384, procs, panes), "%346", "pane_of: the pane's process itself")
eq(locate.pane_of(18441, procs, panes), nil, "pane_of: a terminal window outside tmux has no pane")
eq(locate.pane_of(1, procs, panes), nil, "pane_of: launchd is nobody's pane")
eq(locate.pane_of(999999, procs, panes), nil, "pane_of: an unknown pid")
local loop = { [10] = { pid = 10, ppid = 11, cmd = "a" }, [11] = { pid = 11, ppid = 10, cmd = "b" } }
eq(locate.pane_of(10, loop, {}), nil, "pane_of: a cycle in the tree ends, it does not hang")
eq(locate.ancestors(18441, procs), { 18441, 18410, 18404, 71138 }, "ancestors: the agent, the login, the terminal, its parent")
eq(locate.ancestors(10, loop), { 10, 11 }, "ancestors: a cycle ends")
eq(locate.ancestors(1, procs), {}, "ancestors: launchd has none")

-- by_argv: the agent's own process first, the wrapper after
eq(locate.by_argv("16456e05-f164-4e0b-acee-dd556b9b8086", procs, "claude"), { 47658 }, "by_argv: a claude resume")
eq(locate.by_argv("01a092bb-e050-7ff2-9197-08192f3ec240", procs, "codex"), { 43938 }, "by_argv: a codex resume, by the old id even though codex renames the session")
eq(locate.by_argv("ses_f6d42da6", procs, "opencode"), { 18441 }, "by_argv: the agent's own process, not the terminal or the login that spawned it")
eq(locate.by_argv("ses_f6d42da6", procs, nil), { 18404, 18410, 18441 }, "by_argv: without an agent, anything that names it")
eq(locate.by_argv("nothing-like-this", procs, "claude"), {}, "by_argv: no match")
-- a shell that merely mentions three ids is not any of those sessions
local shell = vim.deepcopy(procs)
shell[90001] = { pid = 90001, ppid = 1, cmd = "/bin/zsh -c echo ses_f6d42da6 01a092bb 16456e05-f164-4e0b-acee-dd556b9b8086" }
eq(locate.by_argv("01a092bb", shell, "codex"), { 43938 }, "by_argv: the real codex, never the shell that names it too")
eq(locate.by_argv("16456e05-f164-4e0b-acee-dd556b9b8086", shell, "claude"), { 47658 }, "by_argv: the real claude, never the shell")
shell[90002] = { pid = 90002, ppid = 1, cmd = "/bin/zsh -c echo ses_nobody-runs-this" }
eq(locate.by_argv("ses_nobody-runs-this", shell, "opencode"), {}, "by_argv: a shell alone proves nothing")

-- the whole thing, on a real process started for this test
local id = "lex-test-" .. vim.uv.os_getpid()
local job = vim.system({ "sleep", "30" }, { detach = false })
local me = locate.locate({ session = id, agent = "claude" })
eq(me, nil, "locate: nothing for a session nobody runs")
job:kill(9)

-- the state file wins when its process is alive
local tmp = vim.fn.tempname()
vim.env.LEX_HOME = tmp
vim.fn.mkdir(tmp .. "/sessions", "p")
local links = require("lex.links")
local mine = vim.uv.os_getpid()
vim.fn.writefile({ vim.json.encode({ state = "idle", pid = mine, pane = "%999", agent = "claude" }) }, tmp .. "/sessions/" .. id .. ".json")
links.forget_sessions()
local loc = locate.locate({ session = id, agent = "claude" })
eq(loc and { loc.pid, loc.how }, { mine, "state" }, "locate: the state file's live process")
eq(loc and loc.pane, locate.pane_of(mine, locate.processes(), locate.panes()), "locate: the pane is walked from the process, never the stored %999")
vim.fn.writefile({ vim.json.encode({ state = "ended", pid = mine, agent = "claude" }) }, tmp .. "/sessions/" .. id .. ".json")
links.forget_sessions()
eq(locate.locate({ session = id, agent = "claude" }), nil, "locate: an ended session is not running")
vim.fn.writefile({ vim.json.encode({ state = "idle", pid = 999999999, agent = "claude" }) }, tmp .. "/sessions/" .. id .. ".json")
links.forget_sessions()
eq(locate.locate({ session = id, agent = "claude" }), nil, "locate: a dead pid in the state file is no answer")
vim.fn.delete(tmp, "rf")
vim.env.LEX_HOME = nil

-- session_file: only Codex keeps its session file open, so only Codex is
-- worth an lsof; the others cost 180 ms to be told no
eq(locate.session_file({ agent = "claude", transcript = "/x/y.jsonl", session = "s" }), nil, "session_file: claude closes its transcript, so none")
eq(locate.session_file({ agent = "opencode", session = "ses_x" }), nil, "session_file: opencode has none")
eq(locate.session_file({ agent = "codex", transcript = "/no/such/rollout.jsonl", session = "01a0-none" }), nil, "session_file: a codex rollout that is not there")
local rollout = vim.fn.tempname() .. ".jsonl"
vim.fn.writefile({ "{}" }, rollout)
eq(locate.session_file({ agent = "codex", transcript = rollout, session = "s" }), rollout, "session_file: the codex rollout the record names")
vim.fn.delete(rollout)
eq(locate.by_open_file("/no/such/file"), nil, "by_open_file: a missing file")
eq(locate.by_open_file(nil), nil, "by_open_file: no path")

-- by_open_files: one lsof for many paths, parsed from its -F pn output
eq(
  locate.by_open_files({}, "p123\nn/a/one.jsonl\np456\nn/b/two.jsonl\nn/b/three.jsonl\n"),
  { ["/a/one.jsonl"] = 123, ["/b/two.jsonl"] = 456, ["/b/three.jsonl"] = 456 },
  "by_open_files: every file of every process block"
)
eq(locate.by_open_files({}, ""), {}, "by_open_files: nothing open")
eq(locate.by_open_files({}, "n/no/process/line.jsonl\n"), {}, "by_open_files: a name with no process before it is skipped")

io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
