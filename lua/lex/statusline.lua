-- lex.statusline: the `💬 N` chip, and the click that opens the picker.
--
-- A lualine component is a function that returns text; the colour and the
-- click are the spec's business, and `click(button)` is what the spec calls.
--
-- Two numbers, `💬 9/12`: this file, and the whole project. The file's
-- conversations are a part of the project's, so the shape says "9 of 12"
-- and each half is what one mouse button opens.
--
-- Printed always, never empty, so the bar does not shift: `💬 -/12` in a
-- buffer that is not a file, `💬 0/12` in a file with no links, `💬 -`
-- outside any repository. A conversation counts once however many places it
-- put in the file (lex.conv). The file number leaves out the places whose
-- lines are gone from the file; the project number leaves out the
-- conversations whose transcript is gone. Neither can be resolved for the
-- other, and both are cached: the file's by the marks, the project's until
-- the store changes.
--
-- Left click is this file, right click is the whole project, the convention
-- the rest of Lukas's bar already uses: left drills into the thing you are
-- looking at, right shows the wider report (mac-setup, plugins/
-- statusline.lua). In a buffer that is not a file there is nothing to drill
-- into, so either button opens the project.

local marks = require("lex.marks")

local M = {}

--- The count for the current buffer, or nil for a non-file buffer.
---@return integer|nil
function M.count()
  local st = marks.state(vim.api.nvim_get_current_buf())
  if not st then
    return nil
  end
  return st.count
end

--- The repository of the current buffer, or of the working directory.
---@return string|nil
local function repo_of()
  local st = marks.state(vim.api.nvim_get_current_buf())
  if st then
    return st.repo
  end
  local ok, repo = pcall(function()
    return (require("lex.links").roots(vim.fn.getcwd()))
  end)
  if not ok or not repo then
    return nil
  end
  -- Outside a repository `roots` answers with the directory itself, and a
  -- count for a random directory means nothing. `💬 -` says so.
  return vim.uv.fs_stat(repo .. "/.git") and repo or nil
end

--- How many conversations the whole project holds, or nil outside one.
---@return integer|nil
function M.project_count()
  local repo = repo_of()
  if not repo then
    return nil
  end
  local ok, n = pcall(require("lex.conv").count_repo, repo)
  return ok and n or nil
end

--- The chip text.
---@return string
function M.component()
  local icon = require("lex").config.icon
  local here, all = M.count(), M.project_count()
  if not all then
    return icon .. " -"
  end
  return ("%s %s/%d"):format(icon, here and tostring(here) or "-", all)
end

--- Open the picker. `"l"` or nothing: this file. `"r"`: every conversation
--- in the repository.
---@param button? string  the lualine click button: "l", "m" or "r"
function M.click(button)
  local picker = require("lex.picker")
  local buf = vim.api.nvim_get_current_buf()
  local st = marks.state(buf)
  if button == "r" or not st then
    local scope = picker.scope_repo(buf)
    if not scope.repo then
      return vim.notify("Lex: not in a repository", vim.log.levels.INFO)
    end
    return picker.pick(scope)
  end
  picker.pick({ kind = "file", repo = st.repo, rel = st.file, buf = buf, title = "Lex · " .. st.file })
end

return M
