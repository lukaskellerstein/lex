-- Tests for lex.place. Run: nvim -l tests/place_test.lua
-- No framework: a failing check raises, and the exit code says so.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(_G.arg[0], ":p"))))
vim.opt.runtimepath:prepend(root)

local place = require("lex.place")
local checks, failed = 0, 0

local function eq(got, want, what)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

-- block(): the three forms
eq(
  place.block({ path = "/a/src/x.ts", repo = "/a", file = "src/x.ts", from = 12, to = 15, lang = "typescript", body = "one\ntwo" }),
  '<lex-place path="/a/src/x.ts" repo="/a" file="src/x.ts" lines="12-15" lang="typescript">\none\ntwo\n</lex-place>',
  "block: a range"
)
eq(place.block({ path = "/a/src/x.ts", repo = "/a", file = "src/x.ts" }), '<lex-place path="/a/src/x.ts" repo="/a" file="src/x.ts"/>', "block: a whole file")
eq(place.block({ path = "/a/src", repo = "/a", dir = "src" }), '<lex-place path="/a/src" repo="/a" dir="src"/>', "block: a folder")
eq(place.block({ path = '/a/we"ird.ts', repo = "/a", file = 'we"ird.ts' }), '<lex-place path="/a/we&quot;ird.ts" repo="/a" file="we&quot;ird.ts"/>', "block: a quote in a path")
eq(place.block({ path = "/a/b&c<d>.ts", repo = "/a", file = "b&c<d>.ts" }), '<lex-place path="/a/b&amp;c&lt;d&gt;.ts" repo="/a" file="b&amp;c&lt;d&gt;.ts"/>', "block: & < > in a path")
eq(place.block({ n = 2, path = "/a/src/x.ts", repo = "/a", file = "src/x.ts", from = 3, to = 3, lang = "lua", body = "x" }), '<lex-place n="2" path="/a/src/x.ts" repo="/a" file="src/x.ts" lines="3-3" lang="lua">\nx\n</lex-place>', "block: n comes first")
eq(place.block({ n = 1, path = "/a/src", repo = "/a", dir = "src" }), '<lex-place n="1" path="/a/src" repo="/a" dir="src"/>', "block: n on a folder")

-- the collision guard: a body that spells the tag renames the tag, never the body
eq(place.tag_for("plain code"), "lex-place", "tag_for: bare")
eq(place.tag_for("see </lex-place> here"), "lex-place-1", "tag_for: the close form")
eq(place.tag_for('<lex-place path="x"/>'), "lex-place-1", "tag_for: the open form")
eq(place.tag_for("</lex-place> and </lex-place-1>"), "lex-place-2", "tag_for: two suffixes spelled")
eq(place.tag_for("<lex-placeholder>"), "lex-place", "tag_for: a longer word is not the tag")
local spelled = place.block({ path = "/a/hook.lua", repo = "/a", file = "hook.lua", from = 5, to = 6, lang = "lua", body = 'local s = "</lex-place>"\nlocal t = "<lex-place-1 x>"' })
eq(spelled, '<lex-place-2 path="/a/hook.lua" repo="/a" file="hook.lua" lines="5-6" lang="lua">\nlocal s = "</lex-place>"\nlocal t = "<lex-place-1 x>"\n</lex-place-2>', "block: renamed with the smallest free suffix, body untouched")

-- parse(): round trip, in order, with the question around the blocks
local prompt = table.concat({
  "Look at these:",
  place.block({ path = "/a/src/x.ts", repo = "/a", file = "src/x.ts", from = 1, to = 2, lang = "typescript", body = "l1\nl2" }),
  "and",
  place.block({ path = "/a/src", repo = "/a", dir = "src" }),
  place.block({ path = "/a/README.md", repo = "/a", file = "README.md" }),
  "Why does it retry?",
}, "\n")
eq(place.parse(prompt), {
  { path = "/a/src/x.ts", repo = "/a", file = "src/x.ts", from = 1, to = 2, lang = "typescript", body = "l1\nl2" },
  { path = "/a/src", repo = "/a", dir = "src" },
  { path = "/a/README.md", repo = "/a", file = "README.md" },
}, "parse: three places in order")
eq(place.parse("no places here"), {}, "parse: none")
eq(place.parse('<lex-place path="/a" repo="/a" file="f" lines="x-y">\nb\n</lex-place>'), {}, "parse: bad lines is skipped")
eq(place.parse(place.block({ path = '/a/we"ird.ts', repo = "/a", file = 'we"ird.ts' })), { { path = '/a/we"ird.ts', repo = "/a", file = 'we"ird.ts' } }, "parse: the quote comes back")
eq(place.parse(place.block({ path = "/a/b&c<d>.ts", repo = "/a", file = "b&c<d>.ts" })), { { path = "/a/b&c<d>.ts", repo = "/a", file = "b&c<d>.ts" } }, "parse: & < > come back")
eq(place.parse(place.block({ n = 7, path = "/a/x.ts", repo = "/a", file = "x.ts", from = 1, to = 1, lang = "ts", body = "a" })), { { n = 7, path = "/a/x.ts", repo = "/a", file = "x.ts", from = 1, to = 1, lang = "ts", body = "a" } }, "parse: n is a number")
eq(place.parse('<lex-place n="x" path="/a/x.ts" repo="/a" file="x.ts"/>'), {}, "parse: a bad n is skipped")
eq(place.parse(spelled .. "\nwhy?"), { { path = "/a/hook.lua", repo = "/a", file = "hook.lua", from = 5, to = 6, lang = "lua", body = 'local s = "</lex-place>"\nlocal t = "<lex-place-1 x>"' } }, "parse: a renamed block is one place, the body intact")
eq(place.parse('<lex-place-9 path="/a/x.ts" repo="/a" file="x.ts" lines="1-1">\nb\n</lex-place>'), {}, "parse: a mismatched suffix does not close the block")
eq(place.parse('<lex-place-1 path="/a/x.ts" repo="/a" file="x.ts" lines="1-1">\n</lex-place>\n</lex-place-1>'), { { path = "/a/x.ts", repo = "/a", file = "x.ts", from = 1, to = 1, body = "</lex-place>" } }, "parse: a bare close tag inside a suffixed block is body")
eq(
  place.parse('<lex-place path="/a/src" repo="/a" dir="src"/>\n<lex-place path="/a/x.ts" repo="/a" file="x.ts" lines="1-1">\nb\n</lex-place>'),
  { { path = "/a/src", repo = "/a", dir = "src" }, { path = "/a/x.ts", repo = "/a", file = "x.ts", from = 1, to = 1, body = "b" } },
  "parse: a self-closing block before a closed block is not swallowed"
)
eq(place.parse('<lex-place-3 path="/a/src" repo="/a" dir="src"/>'), { { path = "/a/src", repo = "/a", dir = "src" } }, "parse: a suffixed self-closing block")
eq(place.parse('<lex-place path="/a/x.ts" repo="/a" file="x.ts" lines="5-3">\nb\n</lex-place>'), {}, "parse: a backwards range is skipped")
eq(place.parse('<lex-place path="/a/x.ts" repo="/a" file="x.ts" lines="0-3">\nb\n</lex-place>'), {}, "parse: a range from line 0 is skipped")

-- the contract prompt: the reference parser agrees with the writers' records
local contract = table.concat(vim.fn.readfile(root .. "/contract/prompt.txt"), "\n") .. "\n"
local want = vim.json.decode(table.concat(vim.fn.readfile(root .. "/contract/records.json"), "\n"))
local got = place.parse(contract)
eq(#got, #want, "contract: the same number of places")
for i, p in ipairs(got) do
  local w = want[i]
  eq({ p.repo, p.path, p.file, p.dir, p.from, p.to, p.lang }, { w.repo, w.path, w.file, w.dir, w.from, w.to, w.lang }, ("contract: place %d"):format(i))
  eq(p.n or i, w.index, ("contract: place %d index"):format(i))
end

-- roots(): a real repo and a real worktree, in a temp dir
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/main/src", "p")
local function git(dir, ...)
  local out = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(out.code == 0, out.stderr)
  return out.stdout
end
git(tmp .. "/main", "init", "-q")
git(tmp .. "/main", "config", "user.email", "t@example.com")
git(tmp .. "/main", "config", "user.name", "t")
vim.fn.writefile({ "a" }, tmp .. "/main/src/x.ts")
git(tmp .. "/main", "add", ".")
git(tmp .. "/main", "commit", "-q", "-m", "init")
git(tmp .. "/main", "worktree", "add", "-q", tmp .. "/main/.worktrees/w1")
local main = vim.uv.fs_realpath(tmp .. "/main")
local repo, top = place.roots(main .. "/src/x.ts")
eq({ repo, top }, { main, main }, "roots: main checkout")
repo, top = place.roots(main .. "/.worktrees/w1/src/x.ts")
eq({ repo, top }, { main, main .. "/.worktrees/w1" }, "roots: a worktree keys on the main root")
repo, top = place.roots(tmp)
eq({ repo, top }, { tmp, tmp }, "roots: outside git")

-- for_path(): file, folder, the root itself
eq(place.for_path(main .. "/.worktrees/w1/src/x.ts"), { path = main .. "/.worktrees/w1/src/x.ts", repo = main, file = "src/x.ts" }, "for_path: a file in a worktree")
eq(place.for_path(main .. "/src"), { path = main .. "/src", repo = main, dir = "src" }, "for_path: a folder")
eq(place.for_path(main), { path = main, repo = main, dir = "." }, "for_path: the repo root")

-- for_buffer(): a range, and the whole buffer
vim.cmd("edit " .. main .. "/src/x.ts")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
vim.bo[buf].filetype = "typescript"
eq(place.for_buffer(buf, 2, 3), { path = main .. "/src/x.ts", repo = main, file = "src/x.ts", from = 2, to = 3, lang = "typescript", body = "two\nthree" }, "for_buffer: a range")
eq(place.for_buffer(buf, 1, 3), { path = main .. "/src/x.ts", repo = main, file = "src/x.ts" }, "for_buffer: the whole buffer is a whole-file place")

-- describe()
eq(place.describe({ path = "/a/x.ts", repo = "/a", file = "x.ts", from = 3, to = 3 }), "line 3 of x.ts", "describe: one line")
eq(place.describe({ path = "/a/x.ts", repo = "/a", file = "x.ts", from = 3, to = 9 }), "lines 3-9 of x.ts", "describe: a range")
eq(place.describe({ path = "/a/x.ts", repo = "/a", file = "x.ts" }), "x.ts, whole file", "describe: a whole file")
eq(place.describe({ path = "/a/src", repo = "/a", dir = "src" }), "folder src, every file under it", "describe: a folder")

vim.fn.delete(tmp, "rf")
io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
