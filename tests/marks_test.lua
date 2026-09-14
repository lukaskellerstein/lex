-- Tests for lex.links, lex.pending, lex.marks, lex.explorer and the picker's
-- item list. Run: nvim -l tests/marks_test.lua
--
-- A temporary git repository with a worktree, a temporary store written the
-- way the hook writes it, and real buffers with real extmarks, headless.

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/main/src/auth", "p")
vim.fn.mkdir(tmp .. "/main/docs", "p")
vim.env.LEX_HOME = tmp .. "/store"

local function git(dir, ...)
  local out = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(out.code == 0, out.stderr)
end
git(tmp .. "/main", "init", "-q")
git(tmp .. "/main", "config", "user.email", "t@example.com")
git(tmp .. "/main", "config", "user.name", "t")
local lines = {}
for i = 1, 40 do
  lines[i] = ("  local v%d = f(%d)"):format(i, i)
end
vim.fn.writefile(lines, tmp .. "/main/src/auth/login.lua")
vim.fn.writefile({ "# docs" }, tmp .. "/main/docs/README.md")
vim.fn.writefile({ "x" }, tmp .. "/main/src/other.lua")
git(tmp .. "/main", "add", ".")
git(tmp .. "/main", "commit", "-q", "-m", "init")
git(tmp .. "/main", "worktree", "add", "-q", tmp .. "/main/.worktrees/w1")
local main = vim.uv.fs_realpath(tmp .. "/main")

require("lex").setup({})
local links = require("lex.links")
local pending = require("lex.pending")
local marks = require("lex.marks")
local explorer = require("lex.explorer")
local picker = require("lex.picker")
local place = require("lex.place")
local store = require("lex.store")

-- roots(): the same answer as lex.place.roots, without git
for _, p in ipairs({ main .. "/src/auth/login.lua", main .. "/.worktrees/w1/src/auth/login.lua", main .. "/docs", main, vim.uv.fs_realpath(tmp) }) do
  eq({ links.roots(p) }, { place.roots(p) }, "roots: agrees with place.roots for " .. p:sub(#tmp + 1))
end

-- the store, written the way the hook writes it
local function record(over)
  local body = table.concat(lines, "\n", over.from or 1, over.to or 1)
  local r = {
    at = os.time() - 3600,
    agent = "claude",
    session = "s-" .. tostring(over.from or over.dir or "file"),
    pid = 999999999,
    pane = "%1",
    transcript = tmp .. "/transcript.jsonl",
    cwd = main,
    repo = main,
    path = main .. "/src/auth/login.lua",
    file = "src/auth/login.lua",
    index = 1,
    of = 1,
    prompt = "Why does login retry twice?",
  }
  if over.from then
    r.from, r.to, r.body, r.lang = over.from, over.to, body, "lua"
    r.head, r.tail = vim.trim(lines[over.from]), vim.trim(lines[over.to])
  end
  for k, v in pairs(over) do
    r[k] = v
  end
  if r.dir then
    r.file, r.from, r.to, r.body = nil, nil, nil, nil
    r.path = main .. "/" .. r.dir
  end
  return vim.json.encode(r)
end
vim.fn.writefile({ '{"type":"assistant","message":{"content":[{"type":"text","text":"Because the gateway drops calls."}]}}' }, tmp .. "/transcript.jsonl")
vim.fn.mkdir(vim.fs.dirname(store.file(main)), "p")
vim.fn.writefile({
  record({ from = 6, to = 16 }),
  record({ from = 6, to = 16, session = "s-second", at = os.time() - 60, prompt = "Extract the retry" }),
  record({ from = 14, to = 19, session = "s-overlap" }),
  record({ session = "s-whole", transcript = tmp .. "/missing.jsonl" }),
  record({ dir = "src", session = "s-dir" }),
  record({ file = "src/other.lua", path = main .. "/src/other.lua", session = "s-other" }),
}, store.file(main))

-- links: the file's records, folders included
local r = links.repo(main)
eq(#r.records, 6, "links: six records")
eq(#links.for_file(main, "src/auth/login.lua"), 5, "links: four on the file plus the folder above")
eq(#links.for_file(main, "docs/README.md"), 0, "links: nothing on docs")
eq(#links.on_dir(main, "src"), 1, "links: one folder place on src")
eq(#links.above(main, "src/auth/login.lua"), 1, "links: one folder above the file")
eq(#links.under_dir(main, "src"), 6, "links: everything is under src")
eq(links.gone(r.records[4]), true, "links: a missing transcript is gone")
eq(links.gone(r.records[1]), false, "links: a present transcript is not gone")
eq(links.running(r.records[1]), false, "links: pid 999999999 is not running")
eq(links.age(os.time() - 90), "1m", "age: minutes")
eq(links.age(os.time() - 7200), "2h", "age: hours")
eq(links.age(os.time() - 3 * 86400), "3d", "age: days")

-- the tail read: one more record, only the new line is read
local f = assert(io.open(store.file(main), "a"))
f:write(record({ from = 30, to = 31, session = "s-late", at = os.time() }), "\n")
f:close()
eq(links.refresh(r), true, "links: a tail read finds the new record")
eq(#r.records, 7, "links: seven now")
eq(links.refresh(r), false, "links: nothing more to read")
f = assert(io.open(store.file(main), "a"))
f:write('{"partial": ')
f:close()
eq(links.refresh(r), false, "links: a half-written line waits")
f = assert(io.open(store.file(main), "a"))
f:write('"x"}\n')
f:close()
eq(links.refresh(r), false, "links: the finished line is not a record and is skipped")
eq(#r.records, 7, "links: still seven")

-- marks: the buffer, resolved and painted
vim.cmd("edit " .. main .. "/src/auth/login.lua")
local buf = vim.api.nvim_get_current_buf()
marks.attach(buf)
local st = marks.state(buf)
eq(st and st.file, "src/auth/login.lua", "marks: the buffer's file")
eq(#st.ranges, 3, "marks: three distinct ranges")
eq({ st.ranges[1].from, st.ranges[1].to, #st.ranges[1].recs }, { 6, 16, 2 }, "marks: two conversations on 6-16")
eq({ st.ranges[2].from, st.ranges[2].to }, { 14, 19 }, "marks: the overlapping range")
eq(#st.whole, 0, "marks: the whole-file place is gone and not painted")
eq(#st.folder, 1, "marks: the folder place applies")
eq(st.count, 5, "marks: five that still have a place")

local ns_static = vim.api.nvim_create_namespace("lex_static")
local ns_badge = vim.api.nvim_create_namespace("lex_badge")
-- nvim pads a sign to two cells, so a one-bar sign reads back as "▎ "
local function sign_at(row)
  local ms = vim.api.nvim_buf_get_extmarks(buf, ns_static, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  local sign = ms[1] and ms[1][4].sign_text
  return sign and vim.trim(sign), ms[1] and ms[1][4].line_hl_group
end
eq({ sign_at(1) }, { "▎", nil }, "static: row 1 has the folder lane and no wash")
eq({ sign_at(6) }, { "▎▎", "LexWash1" }, "static: row 6 one range plus the folder lane, tone 1")
eq({ sign_at(15) }, { "▎▎", "LexWash2" }, "static: row 15 two ranges overlap, tone 2")
eq({ sign_at(25) }, { "▎", nil }, "static: row 25 the folder lane only")
eq({ sign_at(30) }, { "▎▎", "LexWash1" }, "static: row 30 the late record")

local function badges(row)
  local ms = vim.api.nvim_buf_get_extmarks(buf, ns_badge, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  local out = {}
  for _, m in ipairs(ms) do
    local text = {}
    for _, chunk in ipairs(m[4].virt_text) do
      text[#text + 1] = chunk[1]
    end
    out[#out + 1] = table.concat(text)
  end
  return out
end
eq(badges(6), { " 💬 2 " }, "badge: row 6 counts two conversations, cursor elsewhere")
eq(badges(1), { " 💬 1  folder src/ " }, "badge: row 1 says folder")
vim.api.nvim_win_set_cursor(0, { 10, 0 })
marks.badges(buf)
eq(badges(6), { " 💬 2  Extract the retry  ·  1m " }, "badge: cursor inside shows the newest prompt and its age")
eq(marks.count_at(buf, 15), 4, "count_at: two ranges plus the folder on row 15")
eq(marks.count_at(buf, 25), 1, "count_at: only the folder on row 25")
eq(#marks.records_at(buf, 15), 4, "records_at: the same four")

-- the wash toggle
require("lex").config.wash = false
marks.refresh(buf)
eq({ sign_at(6) }, { "▎▎", nil }, "wash off: the bar stays, the wash goes")
require("lex").config.wash = true
marks.refresh(buf)

-- an edit moves the marks: insert five lines at the top and repaint
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a", "-- b", "-- c", "-- d", "-- e" })
marks.refresh(buf)
st = marks.state(buf)
eq({ st.ranges[1].from, st.ranges[1].to }, { 11, 21 }, "edit: the range moved down five rows")
eq({ sign_at(6) }, { "▎", nil }, "edit: row 6 is plain now")
eq({ sign_at(11) }, { "▎▎", "LexWash1" }, "edit: row 11 is the range's first row now")
vim.api.nvim_buf_set_lines(buf, 0, 5, false, {})
marks.refresh(buf)

-- pending: a copy paints blue and wins the wash; the record's arrival drops it
local p = place.for_buffer(buf, 15, 18)
local n = pending.add(p)
eq(n, 1, "pending: the first copy is 1")
eq(pending.add(place.for_path(main .. "/docs")), 2, "pending: the second is 2")
marks.refresh(buf)
eq({ sign_at(15) }, { "▎┆", "LexPendingWash" }, "pending: row 15 blue over history")
eq({ sign_at(17) }, { "▎┆", "LexPendingWash" }, "pending: row 17 blue over one range and the folder")
eq(badges(15), { " 📌 1 " }, "pending: the hollow pin")
f = assert(io.open(store.file(main), "a"))
f:write(record({ from = 15, to = 18, session = "s-sent", at = os.time() }), "\n")
f:close()
links.refresh(r)
pending.on_store(main)
eq(#pending.list, 1, "pending: the sent place was dropped, the folder stays")
marks.refresh(buf)
eq({ sign_at(15) }, { "▎▎", "LexWash3" }, "pending: row 15 is history now, three ranges deep")
pending.clear()
eq(pending.next, 1, "pending: a cleared list starts at 1 again")

-- explorer: counts, lost, wash, folder tint
local info = explorer.info(main .. "/src/auth/login.lua", false)
eq({ info.count, info.lost, info.tone, info.folder }, { 5, 1, 1, false }, "explorer: the file counts its own five, one lost, tone 1 from the folder above")
info = explorer.info(main .. "/src", true)
eq({ info.count, info.tone, info.folder }, { 1, 0, true }, "explorer: the folder place on src")
info = explorer.info(main .. "/src/other.lua", false)
eq({ info.count, info.tone }, { 1, 2 }, "explorer: a whole-file place under a folder place, tone 2")
info = explorer.info(main .. "/docs/README.md", false)
eq({ info.count, info.tone, info.pending }, { 0, 0, false }, "explorer: nothing on docs")
pending.add(place.for_path(main .. "/docs"))
info = explorer.info(main .. "/docs/README.md", false)
eq({ info.pending, info.pending_n }, { true, 1 }, "explorer: a pending folder above washes the file")
eq(explorer.wash(info), "LexExplorerPending", "explorer: the pending wash")
eq(#explorer.chunks(info), 1, "explorer: one chunk, the pin")
pending.clear()
info = explorer.info(main .. "/src/auth/login.lua", false)
eq(#explorer.chunks(info), 2, "explorer: the count and the lost")
eq(explorer.wash(info), "LexExplorerWash1", "explorer: tone 1")

-- the picker's items: one row per conversation, newest first, gone last
local items = picker.items({ kind = "range", repo = main, rel = "src/auth/login.lua", buf = buf, row = 15 })
eq(#items, 5, "picker: five conversations on row 15")
eq(items[1].conv.session, "s-sent", "picker: newest first")
eq(items[#items].gone, false, "picker: none gone on the row")
items = picker.items({ kind = "file", repo = main, rel = "src/auth/login.lua", buf = buf })
eq(#items, 7, "picker: seven on the file")
eq(items[#items].conv.session, "s-whole", "picker: the gone one last")
items = picker.items({ kind = "folder", repo = main, rel = "src" })
eq(#items, 8, "picker: eight under src")
eq(#picker.items({ kind = "repo", repo = main }), 8, "picker: the repo scope, every conversation")
-- the file's picker and the project's name their scope in the same spot
eq(picker.title("file", "src/auth/login.lua"), "Lex · this file · src/auth/login.lua", "picker: the file's title")
eq(picker.title("repo", "main"), "Lex · whole project · main", "picker: the project's title")
eq(picker.title("range", "login.lua", 15), "Lex · line 15 · login.lua", "picker: a range's title")
eq(picker.title("folder", "src/"), "Lex · folder · src/", "picker: a folder's title")
-- the keys at the foot of the list: all of them when there is room, the last
-- ones dropped first, never cut (nvim would keep the end)
local function cells(footer)
  local n = 0
  for _, chunk in ipairs(footer or {}) do
    n = n + vim.api.nvim_strwidth(chunk[1])
  end
  return n
end
local full = picker.footer()
eq(full[2][1], " Enter ", "picker: the footer starts with Enter")
eq(cells(picker.footer(cells(full))), cells(full), "picker: the whole footer when it fits")
local cut = picker.footer(cells(full) - 1)
eq(cut[#cut - 1][1], " search ", "picker: the last key dropped first")
eq(picker.footer(5), nil, "picker: no footer when not even Enter fits")
local default = { layout = { box = "horizontal", { box = "vertical", border = true, title = "{title} {live} {flags}", { win = "input", border = "bottom" }, { win = "list", border = "none" } }, { win = "preview", border = true } } }
picker.with_keys(default)
eq(default.layout[1].lex_keys, true, "picker: the keys on the frame that carries the title")
local ivy = { layout = { box = "vertical", border = "top", title = " {title} {live} {flags}", { win = "input", border = "bottom" }, { box = "horizontal", { win = "list", border = "none" }, { win = "preview", border = "left" } } } }
picker.with_keys(ivy)
eq({ ivy.layout.lex_keys, ivy.layout[2][1].lex_keys }, {}, "picker: no keys where nothing has a bottom edge")

-- working: the state file says so, and the process lives
local function set_state(session, state)
  vim.fn.mkdir(tmp .. "/store/sessions", "p")
  vim.fn.writefile({ vim.json.encode({ state = state, at = os.time(), agent = "claude" }) }, tmp .. "/store/sessions/" .. session .. ".json")
  links.forget_sessions()
end
f = assert(io.open(store.file(main), "a"))
f:write(record({ from = 30, to = 31, session = "s-live", pid = vim.uv.os_getpid(), at = os.time() }), "\n")
f:close()
links.refresh(r)
local live = r.records[#r.records]
eq(links.running(live), false, "running: no state file, not working, even with a live pid")
set_state("s-live", "working")
eq(links.running(live), true, "running: working and alive")
set_state("s-live", "idle")
eq(links.running(live), false, "running: idle after Stop")
set_state("s-live", "working")
set_state("s-late", "working")
eq(links.running(r.records[7]), false, "running: working but the process is dead")
marks.refresh(buf)
st = marks.state(buf)
local working = {}
for _, rg in ipairs(st.ranges) do
  working[#working + 1] = ("%d:%s"):format(rg.from, tostring(rg.working))
end
eq(working, { "6:false", "14:false", "15:false", "30:true" }, "marks: only the live, working range says so")
eq(badges(30)[1]:find("working…", 1, true) ~= nil, true, "badge: working… on row 30")
set_state("s-live", "idle")
vim.api.nvim_exec_autocmds("User", { pattern = "LexSessionChanged" })
eq(badges(30)[1]:find("working…", 1, true), nil, "badge: gone after Stop")

eq(links.alive(live), true, "alive: a living process, whatever the state says")
eq(links.alive(r.records[7]), false, "alive: a dead process")
eq(links.alive({}), false, "alive: no pid")

-- where: the state file knows the pid and pane of a resumed session
local function set_state_full(session, state, pid, pane)
  vim.fn.mkdir(tmp .. "/store/sessions", "p")
  vim.fn.writefile({ vim.json.encode({ state = state, at = os.time(), agent = "claude", pid = pid, pane = pane }) }, tmp .. "/store/sessions/" .. session .. ".json")
  links.forget_sessions()
end
local stale = r.records[7] -- pid 999999999, pane %1
set_state_full("s-late", "idle", vim.uv.os_getpid(), "%77")
eq(links.where(stale), { pid = vim.uv.os_getpid(), pane = "%77", state = "idle" }, "where: the state file's pid and pane win over the record's")
eq(links.alive(stale), true, "alive: a resumed session is alive through its state file")
set_state_full("s-late", "ended", vim.uv.os_getpid(), "%77")
eq(links.where(stale), { state = "ended" }, "where: an ended session has no pid and no pane")
eq(links.alive(stale), false, "alive: ended is not alive, whatever the pid")
eq(links.where(r.records[1]), { pid = 999999999, pane = "%1" }, "where: no state file, the record's own")

-- open: the tmux sessions, sorted for the chooser (pure)
local open = require("lex.open")
local sessions = open.parse_sessions(table.concat({
  "old\t3\t0\t1700000000",
  "work\t12\t1\t1789000000",
  "lab\t2\t1\t1789100000",
  "scratch\t1\t0\t1789200000",
  "garbage line",
}, "\n"), "lab")
eq(vim.tbl_map(function(t)
  return t.session
end, sessions), { "lab", "work", "scratch", "old" }, "open: this session, then attached, then most recently attached")
eq(sessions[1].label, "tmux lab  ·  2 windows, attached, this one", "open: the label says what it is")
eq(sessions[4].label, "tmux old  ·  3 windows", "open: a detached one")
eq(open.parse_sessions("", nil), {}, "open: no tmux, no sessions")

-- open: the terminal command lines (pure), and the entry in the chooser
local function argv_of(name, ...)
  for _, t in ipairs(open.terminals) do
    if t.name == name then
      return t.argv(...)
    end
  end
end
local cmd = { "claude", "--resume", "41a08397-x" }
eq(argv_of("Ghostty", "/App/ghostty", cmd, "/w d", "41a08397"), { "/App/ghostty", "--working-directory=/w d", "--title=41a08397", "-e", "claude", "--resume", "41a08397-x" }, "terminal: Ghostty")
eq(argv_of("WezTerm", "wezterm", cmd, "/w", "x"), { "wezterm", "start", "--cwd", "/w", "--", "claude", "--resume", "41a08397-x" }, "terminal: WezTerm")
eq(argv_of("kitty", "kitty", cmd, "/w", "x"), { "kitty", "--directory", "/w", "--title", "x", "claude", "--resume", "41a08397-x" }, "terminal: kitty")
eq(argv_of("Alacritty", "alacritty", cmd, "/w", "x"), { "alacritty", "--working-directory", "/w", "--title", "x", "-e", "claude", "--resume", "41a08397-x" }, "terminal: Alacritty")
eq(argv_of("$TERMINAL", "foot", cmd, "/w d", "x"), { "foot", "-e", "sh", "-c", "cd '/w d' && exec 'claude' '--resume' '41a08397-x'" }, "terminal: $TERMINAL through sh, every word quoted")
local osa = argv_of("Terminal.app", "osascript", cmd, "/w", "x")
eq({ osa[1], osa[2], osa[3], osa[5] }, { "osascript", "-e", "tell application \"Terminal\" to do script \"cd '/w' && 'claude' '--resume' '41a08397-x'\"", 'tell application "Terminal" to activate' }, "terminal: Terminal.app through osascript")
local cfg = require("lex").config
cfg.terminal = function()
  return true
end
local labels = vim.tbl_map(function(t)
  return t.label
end, open.targets())
eq(labels[1], "new terminal", "targets: a configured terminal comes first")
eq(vim.tbl_contains(labels, "here  ·  a terminal split in nvim"), false, "targets: no split in nvim any more")
eq(open.new_terminal(cmd, "/w", "x"), true, "new_terminal: the configured function is used")
cfg.terminal = false
labels = vim.tbl_map(function(t)
  return t.label
end, open.targets())
eq(vim.tbl_contains(labels, "new terminal"), false, "targets: terminal = false hides the entry")
cfg.terminal = "no-such-terminal"
eq(open.detect_terminal(), nil, "detect: an unknown name finds nothing")
cfg.terminal = nil
local found = open.detect_terminal()
if found then
  cfg.terminal = found.name:lower()
  eq(open.detect_terminal().name, found.name, "detect: the name picks that terminal")
  cfg.terminal = nil
  eq(open.targets()[1].label, "new terminal", "targets: the detected terminal comes first")
end

-- ── one conversation, many places ──────────────────────────────────────────
--
-- Two places sent in one prompt, a third added to the same session later,
-- one of them in another file. That is one conversation everywhere: one
-- badge count, one explorer count, one picker row.
local conv = require("lex.conv")
local now = os.time()
f = assert(io.open(store.file(main), "a"))
f:write(record({ from = 20, to = 21, session = "s-multi", at = now - 600, index = 1, of = 2, prompt = "are these sections correct?" }), "\n")
f:write(record({ from = 34, to = 35, session = "s-multi", at = now - 600, index = 2, of = 2, prompt = "are these sections correct?" }), "\n")
f:write(record({ file = "docs/README.md", path = main .. "/docs/README.md", from = 1, to = 1, session = "s-multi", at = now - 60, index = 1, of = 1, prompt = "and this one?" }), "\n")
f:close()
links.refresh(r)
marks.refresh(buf)
st = marks.state(buf)
eq(st.count, 8, "multi: the conversation counts once for the file, not twice")
local function badge_count(row)
  local text = badges(row)[1] or ""
  return tonumber(text:match("💬 (%d+)"))
end
eq(badge_count(20), 1, "multi: one conversation on its first place")
eq(badge_count(34), 1, "multi: one on its second place")
eq(marks.count_at(buf, 20), 2, "multi: the row has the conversation and the folder place")

local c = conv.of(main, "s-multi")
eq(#c.places, 3, "conv: three places")
eq(conv.files(c), 2, "conv: in two files")
eq(c.prompts, { "are these sections correct?", "and this one?" }, "conv: the prompts, oldest first, no repeats")
eq(c.at, now - 60, "conv: the newest record's time")
eq(c.started, now - 600, "conv: when it started")
eq(conv.key(c.places[1].rec), "range:src/auth/login.lua:20-21", "conv: a range key")

-- turns: one prompt and the places it carried, oldest first
local turns = conv.turns(c)
eq(#turns, 2, "turns: two prompts")
eq({ turns[1].n, turns[1].prompt, #turns[1].recs }, { 1, "are these sections correct?", 2 }, "turns: the first carried two places")
eq({ turns[2].n, turns[2].prompt, #turns[2].recs }, { 2, "and this one?", 1 }, "turns: the second carried one")
eq({ turns[1].recs[1].from, turns[1].recs[2].from }, { 20, 34 }, "turns: its places in the order they were sent")
eq(turns[1].at < turns[2].at, true, "turns: oldest first")
eq(#conv.turns(conv.of(main, "s-6")), 1, "turns: a one-prompt conversation has one")
eq(conv.count_repo(main) > 0, true, "count_repo: answers")
eq(conv.count_repo(main), conv.count_repo(main), "count_repo: the cache gives the same answer")
eq(conv.key({ file = "x", }), "file:x", "conv: a whole-file key")
eq(conv.key({ dir = "src" }), "dir:src", "conv: a folder key")

items = picker.items({ kind = "file", repo = main, rel = "src/auth/login.lua", buf = buf })
local multi
for _, item in ipairs(items) do
  if item.conv.session == "s-multi" then
    multi = item
  end
end
eq(multi ~= nil, true, "picker: the conversation is in the file's list")
eq(#multi.here, 2, "picker: two of its places are in this file")
eq(#multi.conv.places, 3, "picker: the row still knows all three")
eq(#items, 9, "picker: one row for it, not two")
local repo_items = picker.items({ kind = "repo", repo = main })
eq(#repo_items, 10, "picker: the repo scope has every conversation once")

-- forgetting: one place, then the whole conversation
local before = #links.repo(main).records
eq({ links.forget_place(main, "s-multi", "range:src/auth/login.lua:20-21") }, { 1 }, "forget: one place, one record")
eq(#links.repo(main).records, before - 1, "forget: the store shrank by one")
eq(#conv.of(main, "s-multi").places, 2, "forget: two places left")
eq({ links.forget_session(main, "s-multi") }, { 2 }, "forget: the rest of the conversation")
eq(conv.of(main, "s-multi"), nil, "forget: it is gone")
eq(#links.repo(main).records, before - 3, "forget: the store shrank by three in all")
eq(links.forget_session(main, "s-nothing-like-this"), 0, "forget: an unknown session removes nothing")
marks.refresh(buf)
eq(marks.state(buf).count, 7, "forget: the file is back to the seven it had")

-- forgetting a file: each conversation loses only its places in that file,
-- one with nothing left is gone, and the folder place above stays
vim.fn.writefile({ "# guide" }, tmp .. "/main/docs/guide.md")
vim.fn.writefile({ "# other" }, tmp .. "/main/docs/other.md")
local guide = { file = "docs/guide.md", path = main .. "/docs/guide.md" }
f = assert(io.open(store.file(main), "a"))
for _, over in ipairs({
  vim.tbl_extend("force", guide, { from = 1, to = 1, session = "s-two-files", at = now - 50, prompt = "is the guide right?" }),
  vim.tbl_extend("force", guide, { from = 1, to = 1, session = "s-two-files", at = now - 40, prompt = "and now?" }),
  { file = "docs/other.md", path = main .. "/docs/other.md", from = 1, to = 1, session = "s-two-files", at = now - 40, prompt = "and now?" },
  vim.tbl_extend("force", guide, { session = "s-guide-only", at = now - 30 }),
  { dir = "docs", session = "s-docs-dir", at = now - 20 },
}) do
  f:write(record(over), "\n")
end
f:close()
links.refresh(r)
local asked
local real_confirm, real_notify = vim.fn.confirm, vim.notify
vim.notify = function() end
vim.fn.confirm = function(msg)
  asked = msg
  return 2
end
eq(picker.forget_file(main .. "/docs/guide.md"), false, "forget file: Cancel removes nothing")
eq(asked, table.concat({
  "Forget the links of 2 conversations to docs/guide.md?",
  "1 conversation has other places too, and keeps them.",
  "1 conversation has no other place, so it is gone from every list.",
  "The agents' own history is not touched.",
}, "\n"), "forget file: the confirm says what stays and what goes")
eq(#links.for_file(main, "docs/guide.md"), 4, "forget file: still four records after Cancel")
vim.fn.confirm = function()
  return 1
end
eq(picker.forget_file(main .. "/docs/guide.md"), true, "forget file: Forget removes")
vim.fn.confirm, vim.notify = real_confirm, real_notify
eq(vim.tbl_map(function(rec) return rec.session end, links.for_file(main, "docs/guide.md")), { "s-docs-dir" }, "forget file: only the folder place above is left")
eq(vim.tbl_map(function(p) return p.file end, conv.of(main, "s-two-files").places), { "docs/other.md" }, "forget file: the conversation keeps its other file")
eq(conv.of(main, "s-guide-only"), nil, "forget file: the conversation with no place left is gone")
eq(links.forget_file(main, "docs/guide.md"), 0, "forget file: nothing left to forget")

-- A transcript can disappear without the append-only store changing. The
-- short count cache therefore expires and notices the lifecycle change.
local count_repo = tmp .. "/count-repo"
local count_transcript = tmp .. "/count-transcript.jsonl"
vim.fn.writefile({ "{}" }, count_transcript)
vim.fn.mkdir(vim.fs.dirname(store.file(count_repo)), "p")
local count_file = assert(io.open(store.file(count_repo), "w"))
count_file:write(vim.json.encode({ repo = count_repo, path = count_repo .. "/x.lua", file = "x.lua", session = "count-session", agent = "claude", transcript = count_transcript, at = os.time(), index = 1, of = 1, prompt = "count" }), "\n")
count_file:close()
local old_ttl = conv.COUNT_TTL
conv.COUNT_TTL = 0
eq(conv.count_repo(count_repo), 1, "count_repo: a present transcript counts")
vim.fn.delete(count_transcript)
links.repo(count_repo).records[1]._gone_at = os.time() - 61
eq(conv.count_repo(count_repo), 0, "count_repo: an expired cache notices a deleted transcript")
conv.COUNT_TTL = old_ttl

-- a buffer that is not a file
vim.cmd("enew")
eq(marks.file_of(vim.api.nvim_get_current_buf()), nil, "file_of: a scratch buffer is not a file")

vim.fn.delete(tmp, "rf")
io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
