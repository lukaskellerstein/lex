-- Tests for lex.json. Run: nvim -l tests/json_test.lua

vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(_G.arg[0], ":p")))))

local json = require("lex.json")
local checks, failed = 0, 0

local function eq(got, want, what)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

-- A settings file the way Claude Code writes one: keys in the order a person
-- put them, two-space indent, one item per line. It must come back byte for
-- byte.
local sample = table.concat({
  "{",
  '  "$schema": "https://json.schemastore.org/claude-code-settings.json",',
  '  "includeCoAuthoredBy": false,',
  '  "permissions": {',
  '    "allow": [',
  '      "Read",',
  '      "Bash(git status:*)"',
  "    ],",
  '    "deny": [],',
  '    "defaultMode": "default"',
  "  },",
  '  "model": "claude-fable-5-1[1m]",',
  '  "hooks": {',
  '    "UserPromptSubmit": [',
  "      {",
  '        "hooks": [',
  "          {",
  '            "type": "command",',
  '            "command": "\\"$HOME/.claude/hooks/inbox-state.sh\\" running",',
  '            "timeout": 5',
  "          }",
  "        ]",
  "      }",
  "    ]",
  "  },",
  '  "empty": {},',
  '  "nothing": null,',
  '  "ratio": 0.5,',
  '  "big": 1e+21,',
  '  "text": "tab\\there, quote \\" and \\\\ and é and 😀"',
  "}",
}, "\n")

local root = json.decode(sample)
eq(json.is_object(root), true, "decode: an object")
local keys = {}
for _, kv in ipairs(root.pairs) do
  keys[#keys + 1] = kv[1]
end
eq(keys, { "$schema", "includeCoAuthoredBy", "permissions", "model", "hooks", "empty", "nothing", "ratio", "big", "text" }, "decode: key order kept")
eq(root:get("includeCoAuthoredBy"), false, "decode: false")
eq(root:get("nothing"), vim.NIL, "decode: null")
eq(root:get("ratio"), 0.5, "decode: a float")
eq(root:get("permissions"):get("allow")[2], "Bash(git status:*)", "decode: an array item")
eq(#root:get("permissions"):get("deny"), 0, "decode: an empty array")
eq(#root:get("empty").pairs, 0, "decode: an empty object")
eq(root:get("text"), 'tab\there, quote " and \\ and é and 😀', "decode: escapes and raw UTF-8")
eq(json.decode('"\\u00e9 \\ud83d\\ude00 \\u0041"'), "é 😀 A", "decode: \\u escapes and a surrogate pair")
eq(json.encode("\1"), '"\\u0001"', "encode: a control character")
eq(root:get("hooks"):get("UserPromptSubmit")[1]:get("hooks")[1]:get("command"), '"$HOME/.claude/hooks/inbox-state.sh" running', "decode: nested")

local out = json.encode(root)
eq(out == sample, true, "encode: byte for byte the same file")
if out ~= sample then
  print(vim.diff(sample, out))
end

-- set(): a new key goes last, an old key keeps its place
root:set("model", "x")
root:set("added", true)
keys = {}
for _, kv in ipairs(root.pairs) do
  keys[#keys + 1] = kv[1]
end
eq(keys[4], "model", "set: an existing key keeps its place")
eq(keys[#keys], "added", "set: a new key goes last")
eq(root:get("model"), "x", "set: the value changed")

-- building from scratch, the way the installer does
local o = json.object()
o:set("hooks", json.object())
o:get("hooks"):set("UserPromptSubmit", json.array({ json.object() }))
o:get("hooks"):get("UserPromptSubmit")[1]:set("hooks", json.array())
eq(json.encode(o), '{\n  "hooks": {\n    "UserPromptSubmit": [\n      {\n        "hooks": []\n      }\n    ]\n  }\n}', "encode: built by hand, empties stay [] and {}")

-- numbers
eq(json.encode(json.array({ 1, -2, 3.5, 1e21 })), "[\n  1,\n  -2,\n  3.5,\n  1e+21\n]", "encode: integers without .0, floats as they are")
eq(json.decode("[1e3, -0.25, 7]"), json.array({ 1000, -0.25, 7 }), "decode: number forms")

-- errors
eq(pcall(json.decode, "{"), false, "decode: unterminated object raises")
eq(pcall(json.decode, "[1] x"), false, "decode: trailing characters raise")
eq(pcall(json.decode, '{"a": tru}'), false, "decode: a bad literal raises")

-- whitespace anywhere, and a top-level scalar
eq(json.decode(' \n { "a" : [ ] , "b" : { } } '), (function()
  local x = json.object()
  x:set("a", json.array())
  x:set("b", json.object())
  return x
end)(), "decode: whitespace")
eq(json.decode('"s"'), "s", "decode: a bare string")

io.stdout:write(("%d checks, %d failed\n"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
