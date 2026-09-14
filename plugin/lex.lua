-- lex.nvim: the commands. Sourced once when the plugin loads.

if vim.g.loaded_lex then
  return
end
vim.g.loaded_lex = true

local AGENTS = { "claude", "codex", "opencode" }

-- `<Cmd>LexCopy<CR>` from a mapping keeps Visual mode, which the picker's own
-- range selection needs; `:LexCopy` typed by hand works too.
vim.api.nvim_create_user_command("LexCopy", function()
  require("lex.copy").copy()
end, { desc = "Lex: copy this place for an agent" })

vim.api.nvim_create_user_command("LexInstallHook", function(o)
  require("lex.install").run(o.args)
end, {
  nargs = "?",
  desc = "Lex: install the prompt hook for an agent (claude, codex, opencode)",
  complete = function(lead)
    return vim.tbl_filter(function(a)
      return a:sub(1, #lead) == lead
    end, AGENTS)
  end,
})

vim.api.nvim_create_user_command("LexWash", function()
  require("lex.marks").toggle_wash()
end, { desc = "Lex: the line wash under linked ranges, on or off" })

vim.api.nvim_create_user_command("LexClear", function()
  require("lex.pending").clear()
  vim.notify("Lex: pending places cleared", vim.log.levels.INFO)
end, { desc = "Lex: forget the copied, unsent places" })

vim.api.nvim_create_user_command("LexLinks", function(o)
  local picker = require("lex.picker")
  local marks = require("lex.marks")
  local buf = vim.api.nvim_get_current_buf()
  if not marks.state(buf) and marks.file_of(buf) then
    marks.attach(buf)
  end
  if o.args == "repo" then
    return picker.pick(picker.scope_repo(buf))
  end
  local st = marks.state(buf)
  if not st then
    return vim.notify("Lex: not a file; try :LexLinks repo", vim.log.levels.INFO)
  end
  if o.args == "file" then
    return picker.pick({ kind = "file", repo = st.repo, rel = st.file, buf = buf, title = picker.title("file", st.file) })
  end
  picker.pick(picker.scope_at(buf, vim.api.nvim_win_get_cursor(0)[1]))
end, {
  nargs = "?",
  desc = "Lex: the conversations on this row, on this file (file), or in the whole project (repo)",
  complete = function()
    return { "file", "repo" }
  end,
})
