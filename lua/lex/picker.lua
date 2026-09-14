-- lex.picker: the conversations of a place, in a snacks picker.
--
-- One row is one conversation, never one place: a session you handed two
-- selections at the start and a third one ten minutes later is one thing
-- (lex.conv). The columns say where it touches the current scope, how long
-- ago, which agent, and what was asked; a word is added only for the
-- abnormal case: `working…`, `edited`, `moved`, `lost`, `gone`.
--
-- Four scopes: the range under the cursor, the file, a folder, and the
-- whole repository (`:LexLinks repo`), which is the list of everything the
-- agents have talked about in this project.
--
-- The preview is the conversation: every place it has, in the order they
-- were added, the questions asked, and the last thing the agent said, read
-- from the transcript on demand (Claude Code and Codex keep JSONL, OpenCode
-- answers `opencode export <id>`).
--
--   <CR>  go to the agent, or resume it (lex.open)
--   g     go to the lines in the file
--   d     forget this conversation, after a confirm
--   q     close
--   ?     every key, snacks' own too
--
-- The footer of the list says `<CR>`, `g`, `d` and `?`, so nobody has to
-- know them.
--
-- The right-click menu inside this picker offers the same, through
-- `menu_action`; mac-setup's ai-ref.lua draws it.

local anchor = require("lex.anchor")
local conv = require("lex.conv")
local links = require("lex.links")
local marks = require("lex.marks")

local M = {}

---@class lex.Scope
---@field kind "range"|"file"|"folder"|"repo"
---@field repo string
---@field rel? string         the file or the folder, relative
---@field buf? integer        the buffer, for a range or an open file
---@field row? integer        the row, for a range
---@field title string

---@class lex.Item
---@field conv lex.Conv
---@field here lex.Record[]      the conversation's records inside the scope
---@field res? lex.Resolution    the newest here-record's lines now
---@field gone boolean
---@field running? lex.Location  where its agent is open, when it is
---@field where? string          that, in words, for the row
---@field idx integer

--- The records a scope covers.
---@param scope lex.Scope
---@return lex.Record[]
local function records_of(scope)
  if scope.kind == "range" then
    return marks.records_at(scope.buf, scope.row)
  elseif scope.kind == "file" then
    return links.for_file(scope.repo, scope.rel)
  elseif scope.kind == "folder" then
    return links.under_dir(scope.repo, scope.rel)
  end
  return links.repo(scope.repo).records
end

--- The conversations of a scope, most recent first, gone ones last.
---@param scope lex.Scope
---@return lex.Item[]
function M.items(scope)
  local here = records_of(scope)
  local by_session = {}
  for _, rec in ipairs(here) do
    local list = by_session[rec.session or "?"] or {}
    list[#list + 1] = rec
    by_session[rec.session or "?"] = list
  end
  local res_by = {}
  local st = scope.buf and marks.state(scope.buf)
  if st then
    for _, l in ipairs(st.links) do
      res_by[l.rec] = l.res
    end
  end
  -- One reading of the machine for the whole list: where each conversation
  -- is open right now. A `ps` per row would be absurd, and a row that does
  -- not say whether its agent is still somewhere is half an answer.
  local locate = require("lex.locate")
  local snap = locate.snapshot()
  local groups = conv.group(here)
  local newest = {}
  for _, c in ipairs(groups) do
    newest[#newest + 1] = c.newest
  end
  local where_by = locate.locate_many(newest, snap)
  local items = {}
  for _, c in ipairs(groups) do
    -- the whole conversation, so the preview can show every place it has,
    -- even the ones outside this scope
    local full = conv.of(scope.repo, c.session) or c
    -- One entry per place, newest first: the same block pasted twice into
    -- one session is one place, not two.
    local mine, seen = {}, {}
    local raw = by_session[c.session] or {}
    table.sort(raw, function(a, b)
      return (a.at or 0) > (b.at or 0)
    end)
    for _, rec in ipairs(raw) do
      local k = conv.key(rec)
      if not seen[k] then
        seen[k] = true
        mine[#mine + 1] = rec
      end
    end
    local loc = where_by[c.newest]
    items[#items + 1] = {
      conv = full,
      scope_conv = c,
      here = mine,
      res = res_by[mine[1]],
      gone = conv.gone(c),
      -- `running`, never `loc`: the picker reads `item.loc` as an editor
      -- location and indexes `loc.range` on every `current()`, so a table
      -- of its own there is an error on every cursor move (2026-09-12).
      -- `buf`, `file`, `pos`, `end_pos` and `preview` are its fields too.
      running = loc,
      where = locate.describe(loc, snap),
    }
  end
  table.sort(items, function(a, b)
    if a.gone ~= b.gone then
      return b.gone
    end
    return a.conv.at > b.conv.at
  end)
  for i, item in ipairs(items) do
    item.idx = i
  end
  return items
end

--- One place, as a person reads it.
---@param rec lex.Record
---@param res? lex.Resolution
---@param with_file? boolean
---@return string
local function place_text(rec, res, with_file)
  local what
  if rec.dir then
    what = "folder " .. (rec.dir == "." and "/" or rec.dir .. "/")
  elseif not rec.from then
    what = "whole file"
  else
    local from, to = rec.from, rec.to
    if res and res.from then
      from, to = res.from, res.to
    end
    what = from == to and ("line %d"):format(from) or ("%d-%d"):format(from, to)
  end
  if with_file and rec.file then
    return rec.file .. "  " .. what
  end
  return what
end

--- The column that says where the conversation meets the scope.
---@param item lex.Item
---@param scope lex.Scope
---@return string
local function where(item, scope)
  local n = #item.here
  if scope.kind == "range" or scope.kind == "file" then
    if n == 1 then
      return place_text(item.here[1], item.res)
    end
    return ("%d places"):format(n)
  end
  local files = {}
  for _, rec in ipairs(item.here) do
    files[rec.file or ("dir:" .. tostring(rec.dir))] = true
  end
  local count = vim.tbl_count(files)
  if count == 1 then
    local rec = item.here[1]
    return rec.dir and ((rec.dir == "." and "/" or rec.dir .. "/")) or vim.fs.basename(rec.file)
  end
  return ("%d files"):format(count)
end

--- The one word for the abnormal case, or nil.
---@param item lex.Item
local function word(item)
  if item.gone then
    return "gone", "LexPickerDim"
  end
  if item.res and item.res.state == "orphaned" then
    return "lost", "LexPickerDim"
  end
  if conv.working(item.conv) then
    return "working…", "LexWorking"
  end
  if item.res and item.res.edited then
    return "edited", "LexPickerNote"
  end
  if item.res and item.res.state == "moved" then
    return "moved", "LexPickerNote"
  end
  return nil
end

--- The prompt to show on the row: the newest one that mentioned this scope.
---@param item lex.Item
---@return string
local function prompt_of(item)
  for _, rec in ipairs(item.here) do
    if rec.prompt and rec.prompt ~= "" then
      return rec.prompt
    end
  end
  local prompts = item.conv.prompts
  return prompts[#prompts] or "(no question)"
end

--- The session id, short enough for a column and long enough to recognise.
---@param session string
---@return string
local function short(session)
  return (tostring(session):gsub("^ses_", "")):sub(1, 8)
end

--- What the conversation holds, in numbers: `4 places · 2 files`.
---@param c lex.Conv
---@return string
local function size_of(c)
  local files = conv.files(c)
  local places = ("%d place%s"):format(#c.places, #c.places == 1 and "" or "s")
  if files <= 1 then
    return places
  end
  return ("%s · %d files"):format(places, files)
end

--- The row: the session first, so it can be read and recognised, then the
--- agent, the age, and what the conversation holds. No prompt: every prompt
--- is in the preview, where they belong with their places (Lukas,
--- 2026-09-12). Typing still searches the prompts, through `item.text`.
local function formatter(scope)
  return function(item)
    local c = item.conv
    local dim = item.gone or (item.res and item.res.state == "orphaned")
    local base = dim and "LexPickerDim" or nil
    local chunks = {
      { ("%-9s"):format(short(c.session)), base or "LexPickerLines" },
      { ("%-9s"):format(c.agent or "?"), base or "LexPickerAgent" },
      { ("%5s  "):format(links.age(c.at)), base or "LexPickerDim" },
    }
    -- What it holds, then where its agent is open right now (Lukas,
    -- 2026-09-12: "if it is open somewhere, if it is running somewhere, the
    -- workspace, the tmux tab"). A dash means no process has it.
    local held
    if scope.kind == "range" or scope.kind == "file" then
      held = where(item, scope)
      if #c.places > #item.here then
        held = held .. "  of " .. size_of(c)
      end
    else
      held = size_of(c)
    end
    chunks[#chunks + 1] = { ("%-22s"):format(held), base or "Normal" }
    chunks[#chunks + 1] = { ("%-30s"):format(item.where or "—"), item.where and "LexPickerNote" or "LexPickerDim" }
    local w, hl = word(item)
    if w then
      chunks[#chunks + 1] = { w, hl }
    end
    return chunks
  end
end

-- ── the transcript's last answer ───────────────────────────────────────────

--- The text parts of a transcript message, for the two JSONL shapes.
local function text_of(obj)
  local role, content
  if obj.type == "assistant" or obj.type == "user" then
    role = obj.type
    content = obj.message and obj.message.content
  elseif obj.type == "response_item" and type(obj.payload) == "table" and obj.payload.type == "message" then
    role = obj.payload.role
    content = obj.payload.content
  end
  if not role then
    return nil
  end
  if type(content) == "string" then
    return role, content
  end
  local parts = {}
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if type(part) == "table" and type(part.text) == "string" and (part.type == "text" or part.type == "output_text" or part.type == "input_text") then
      parts[#parts + 1] = part.text
    end
  end
  return role, table.concat(parts, "\n")
end

--- The last assistant text in `opencode export` output.
local function opencode_answer(stdout)
  local ok, obj = pcall(vim.json.decode, stdout or "")
  if not ok or type(obj) ~= "table" then
    return nil
  end
  local last
  for _, m in ipairs(obj.messages or {}) do
    local info = m.info or m
    if info.role == "assistant" then
      local parts = {}
      for _, part in ipairs(m.parts or {}) do
        if part.type == "text" and type(part.text) == "string" then
          parts[#parts + 1] = part.text
        end
      end
      if #parts > 0 then
        last = table.concat(parts, "\n")
      end
    end
  end
  return last
end

--- The last assistant message in a JSONL transcript. Only the last 2 MB are
--- read: a long session's file grows without limit, and the newest turn is
--- always at the end.
local function file_answer(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local size = f:seek("end")
  local from = math.max(0, size - 2 * 1024 * 1024)
  f:seek("set", from)
  if from > 0 then
    f:read("*l")
  end
  local last
  for line in f:lines() do
    if line:find('"assistant"', 1, true) then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" then
        local role, text = text_of(obj)
        if role == "assistant" and text and text ~= "" then
          last = text
        end
      end
    end
  end
  f:close()
  return last
end

--- The last thing the agent said.
---
--- Claude Code and Codex keep a file, and reading its tail costs a
--- millisecond, so those answer at once. OpenCode keeps its sessions in a
--- database and only `opencode export` can read them, which costs 400 ms
--- every time (measured 2026-09-12) -- far too much for a preview that is
--- redrawn on every cursor move. So a `cb` makes the OpenCode call
--- asynchronous, and the preview redraws itself when the answer lands.
---@param rec lex.Record
---@param cb? fun(answer: string|nil)  required to avoid blocking on OpenCode
---@return string|nil answer, boolean pending
function M.last_answer(rec, cb)
  if rec.agent == "opencode" then
    if cb then
      vim.system({ "opencode", "export", rec.session }, { text = true }, function(out)
        vim.schedule(function()
          cb(out.code == 0 and opencode_answer(out.stdout) or nil)
        end)
      end)
      return nil, true
    end
    local out = vim.system({ "opencode", "export", rec.session }, { text = true }):wait(4000)
    return (out and out.code == 0) and opencode_answer(out.stdout) or nil, false
  end
  local path = rec.transcript
  if not path or path == "" or not vim.uv.fs_stat(path) then
    path = require("lex.locate").session_file(rec)
  end
  local answer = (path and vim.uv.fs_stat(path)) and file_answer(path) or nil
  if cb then
    cb(answer)
  end
  return answer, false
end

-- ── the preview ────────────────────────────────────────────────────────────

-- Which preview line is which place, per preview buffer, so a click on a
-- place line can open it. Rebuilt on every render.
local targets = {}

--- The preview: the conversation as it happened. One block per turn, the
--- prompt and the places that came with it, separated by a rule, then the
--- agent's last answer. The lines themselves are not shown: they are in the
--- file, one click away, and they crowded out everything else (Lukas,
--- 2026-09-12). A place line opens the file at its lines: `<CR>`, or a
--- double click.
local function previewer(scope)
  return function(ctx)
    local item = ctx.item
    local c = item.conv
    local rec = c.newest
    local lines, marks_by_line = {}, {}
    local function add(s)
      for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
        lines[#lines + 1] = l
      end
    end
    -- A band, not a markdown rule: a rule under a line of text is a setext
    -- heading, and one rule alone between two blocks reads as belonging to
    -- neither (Lukas, 2026-09-12). A drawn line above and below the title
    -- says "a new section starts here" and cannot be mistaken for markup.
    local width = 56
    local ok, w = pcall(vim.api.nvim_win_get_width, ctx.preview.win.win)
    if ok and w and w > 20 then
      width = math.min(math.max(w - 4, 24), 100)
    end
    local rule = ("─"):rep(width)
    local function band(title)
      add("")
      add(rule)
      add(title)
      add(rule)
      add("")
    end
    local mine = {}
    for _, r in ipairs(item.here) do
      mine[conv.key(r)] = true
    end

    local w = word(item)
    add(("**%s**  ·  %s  ·  %s  ·  %s%s"):format(
      c.agent or "?",
      short(c.session),
      size_of(c),
      links.age(c.at),
      w and ("  ·  " .. w) or ""
    ))
    add("session " .. tostring(c.session))
    add(item.where and ("open in " .. item.where) or "not running anywhere")
    if rec.cwd and rec.cwd ~= rec.repo then
      add("worktree " .. rec.cwd)
    end

    for _, turn in ipairs(conv.turns(c)) do
      band(("**turn %d**  ·  %s"):format(turn.n, links.age(turn.at)))
      add("> " .. (turn.prompt ~= "" and turn.prompt or "(no question)"))
      add("")
      for _, r in ipairs(turn.recs) do
        local marker = mine[conv.key(r)] and "→" or " "
        lines[#lines + 1] = ("%s %s"):format(marker, place_text(r, nil, true))
        marks_by_line[#lines] = r
      end
    end

    -- Never block the list. `answer_read` is set before the call, so moving
    -- the cursor over a row starts at most one read of it; when the answer
    -- lands the preview draws itself again, if that row is still the one.
    if not item.answer_read then
      item.answer_read = true
      local answer, pending = M.last_answer(rec, function(text)
        item.answer = text
        item.pending = false
        local ok, current = pcall(function()
          return ctx.picker:current()
        end)
        if ok and current == item then
          pcall(function()
            ctx.picker:show_preview()
          end)
        end
      end)
      item.answer = answer
      item.pending = pending
    end
    if item.pending and not item.answer then
      band("**the last answer**")
      add("_reading it from the agent…_")
    elseif item.answer then
      band("**the last answer**, in the agent's own words")
      local answer = vim.split(item.answer, "\n", { plain = true })
      for i = 1, math.min(#answer, 120) do
        lines[#lines + 1] = answer[i]
      end
      if #answer > 120 then
        lines[#lines + 1] = "…"
      end
      add("")
      add(rule)
    elseif item.gone then
      band("_the transcript is gone_")
    else
      band("_no answer read from the transcript_")
    end

    ctx.preview:reset()
    ctx.preview:set_lines(lines)
    ctx.preview:highlight({ ft = "markdown" })
    ctx.preview:set_title(("%s · %s"):format(c.agent or "?", short(c.session)))

    local buf = ctx.buf
    targets[buf] = { by_line = marks_by_line, scope = scope, picker = ctx.picker }
    for _, key in ipairs({ "<CR>", "<2-LeftMouse>" }) do
      vim.keymap.set("n", key, function()
        M.open_line(buf)
      end, { buffer = buf, nowait = true, desc = "Lex: open this place" })
    end
  end
end

--- Open the place on the preview's current line, when there is one.
---@param buf integer
function M.open_line(buf)
  local t = targets[buf]
  if not t then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rec = t.by_line[row]
  if not rec then
    return
  end
  if t.picker then
    t.picker:close()
  end
  require("lex.picker").go_to(rec, t.scope)
end

-- ── actions ────────────────────────────────────────────────────────────────

--- Put the cursor on a record's lines, in its file. The preview's place
--- lines and the picker's `g` both land here.
---@param rec lex.Record
---@param scope lex.Scope
function M.go_to(rec, scope)
  if rec.dir then
    return vim.notify("Lex: a folder place has no lines", vim.log.levels.INFO)
  end
  local buf = scope.buf
  local st = buf and marks.state(buf)
  if not (st and st.file == rec.file) then
    local path = (rec.path and vim.uv.fs_stat(rec.path)) and rec.path or (rec.repo .. "/" .. rec.file)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    marks.attach(buf)
  end
  if not rec.from then
    return
  end
  local res
  for _, l in ipairs((marks.state(buf) or { links = {} }).links) do
    if l.rec == rec then
      res = l.res
    end
  end
  res = res or anchor.resolve(rec, anchor.index(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
  if res.state == "orphaned" then
    return vim.notify("Lex: these lines are gone from the file; the picker keeps what they said", vim.log.levels.WARN)
  end
  vim.api.nvim_win_set_cursor(0, { res.from, 0 })
  vim.cmd("normal! zz")
end

--- Forget a conversation, or one of its places. Destructive and not
--- undoable, so it asks first and says what it removed.
---@param item lex.Item
---@param scope lex.Scope
---@param only_place? boolean
---@return boolean removed
function M.forget(item, scope, only_place)
  local c = item.conv
  local place = only_place and item.here[1]
  local what = place and ("the place %s of this conversation"):format(place_text(place, item.res, true))
    or ("this whole conversation, %d place%s in %d file%s"):format(#c.places, #c.places == 1 and "" or "s", conv.files(c), conv.files(c) == 1 and "" or "s")
  local answer = vim.fn.confirm(("Forget %s?\n%s · %s\nThe agent's own history is not touched."):format(what, c.agent or "?", tostring(c.session):sub(1, 8)), "&Forget\n&Cancel", 2)
  if answer ~= 1 then
    return false
  end
  local removed, err
  if place then
    removed, err = links.forget_place(scope.repo, c.session, conv.key(place))
  else
    removed, err = links.forget_session(scope.repo, c.session)
  end
  if err then
    vim.notify("Lex: " .. err, vim.log.levels.ERROR)
    return false
  end
  vim.notify(("Lex: forgot %d link%s"):format(removed, removed == 1 and "" or "s"), vim.log.levels.INFO)
  return removed > 0
end

-- ── the keys, at the foot of the list ──────────────────────────────────────

--- The keys only Lex gives this picker, most wanted first, and `?` for the
--- rest of snacks' own (Lukas, 2026-09-14). The picker starts typing into
--- the search, so the letters are letters there until `Esc`; the footer
--- says so instead of leaving a `d` that searches for "d".
local KEYS = {
  { "<CR>", "open agent" },
  { "g", "go to lines", esc = true },
  { "d", "forget", esc = true },
  { "?", "all keys", esc = true },
}

--- The footer for a window `width` cells wide: as many keys as fit, the
--- last ones dropped first. Too long is not an option: nvim keeps the END
--- of a footer that does not fit, which cut `<CR>` away first (130 columns,
--- 2026-09-14). Nil when not even the first fits, or with no width the
--- whole of it.
---@param width? integer
---@return string[][]|nil
function M.footer(width)
  for n = #KEYS, 1, -1 do
    local out, esc = {}, false
    for i = 1, n do
      local k = KEYS[i]
      if k.esc and not esc then
        esc = true
        out[#out + 1] = { "  Esc, then", "SnacksFooter" }
      end
      out[#out + 1] = { " ", "SnacksFooter" }
      out[#out + 1] = { " " .. k[1] .. " ", "SnacksFooterKey" }
      out[#out + 1] = { " " .. k[2] .. " ", "SnacksFooterDesc" }
    end
    out[#out + 1] = { " ", "SnacksFooter" }
    local cells = 0
    for _, chunk in ipairs(out) do
      cells = cells + vim.api.nvim_strwidth(chunk[1])
    end
    if not width or cells <= width then
      return out
    end
  end
  return nil
end

--- Fit the keys to the window that carries them, now and after every
--- resize while the picker is open: a resize moves the windows but keeps
--- them, so nothing else redraws the footer for the new width.
---@param picker table  a snacks picker
local function fit_keys(picker)
  local function fit()
    if picker.closed then
      return
    end
    local wins = vim.list_extend(vim.tbl_values(picker.layout.box_wins), vim.tbl_values(picker.layout.wins))
    for _, win in ipairs(wins) do
      if win.opts.lex_keys and win:valid() then
        local footer = M.footer(vim.api.nvim_win_get_width(win.win))
        if not vim.deep_equal(footer, win.opts.footer) then
          win.opts.footer = footer
          win:update()
        end
      end
    end
  end
  fit()
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    callback = function()
      if picker.closed then
        return true
      end
      vim.schedule(fit)
    end,
  })
end

local NO_BOTTOM = { [""] = true, none = true, top = true, left = true, right = true, hpad = true }

--- True when a border draws a bottom edge, the only place a footer shows.
---@param border any  a snacks border: true, a name, or nvim's list of chars
---@return boolean
local function has_bottom(border)
  if type(border) == "table" then
    -- nvim repeats a short list, so the bottom edge is char 6 of 8
    local c = border[5 % #border + 1]
    c = type(c) == "table" and c[1] or c
    return c ~= nil and c ~= ""
  end
  return border == true or (type(border) == "string" and not NO_BOTTOM[border])
end

--- A resolved snacks layout with the keys at its foot: on the box or window
--- that carries the picker's title, which is the list's frame in the
--- default preset, else on the list itself. A layout where neither has a
--- bottom edge (`ivy`) shows no keys; `?` still lists them.
---@param layout table  what `Snacks.picker.config.layout` returns
---@return table
function M.with_keys(layout)
  local titled, list
  local function walk(node)
    if type(node.title) == "string" and node.title:find("{title}", 1, true) then
      titled = titled or node
    end
    if node.win == "list" then
      list = node
    end
    for _, child in ipairs(node) do
      walk(child)
    end
  end
  walk(layout.layout)
  local target = (titled and has_bottom(titled.border) and titled) or (list and has_bottom(list.border) and list)
  if target then
    target.footer = M.footer()
    target.lex_keys = true
  end
  return layout
end

-- ── the picker ─────────────────────────────────────────────────────────────

local last_scope

--- Open the picker for a scope.
---@param scope lex.Scope
function M.pick(scope)
  local items = M.items(scope)
  if #items == 0 then
    return vim.notify("Lex: no conversations here", vim.log.levels.INFO)
  end
  last_scope = scope
  for _, item in ipairs(items) do
    item.text = table.concat({
      prompt_of(item),
      item.conv.agent or "",
      item.conv.session or "",
      where(item, scope),
      item.here[1] and (item.here[1].file or item.here[1].dir) or "",
    }, " ")
  end
  Snacks.picker.pick({
    source = "lex",
    title = scope.title,
    -- The layout the user chose, resolved the way snacks resolves it, with
    -- the keys added. A function, so a resize that picks another preset
    -- gets them again. Its `config` hook has run once here and must not run
    -- a second time when snacks resolves the result.
    layout = function(source)
      local layout = Snacks.picker.config.layout(Snacks.picker.config.get({ source = source }))
      layout.config = nil
      return M.with_keys(layout)
    end,
    on_show = fit_keys,
    items = items,
    format = formatter(scope),
    preview = previewer(scope),
    sort = { fields = { "idx" } },
    confirm = function(picker, item)
      picker:close()
      if item then
        require("lex.open").open(item.conv.newest)
      end
    end,
    actions = {
      lex_go = function(picker, item)
        picker:close()
        if item then
          M.go_to(item.here[1] or item.conv.newest, scope)
        end
      end,
      lex_forget = function(picker, item)
        if not item then
          return
        end
        picker:close()
        if M.forget(item, scope) then
          vim.schedule(function()
            M.pick(scope)
          end)
        end
      end,
    },
    win = {
      input = { keys = { ["g"] = { "lex_go", mode = { "n" } }, ["d"] = { "lex_forget", mode = { "n" } } } },
      -- A double click on a row does what <CR> does: go to the agent.
      list = { keys = { ["g"] = "lex_go", ["d"] = "lex_forget", ["<2-LeftMouse>"] = "confirm" } },
    },
  })
end

-- ── scopes ─────────────────────────────────────────────────────────────────

local SCOPE_WORDS = { file = "this file", folder = "folder", repo = "whole project" }

--- A picker's title: the scope in words, then the path or the project's
--- name. The words come first and in the same spot for every scope, so the
--- file's picker and the whole project's tell themselves apart at a glance
--- (Lukas, 2026-09-14), and a long path cut at the window's edge still
--- leaves them.
---@param kind "range"|"file"|"folder"|"repo"
---@param what string  the path, or the project's name
---@param row? integer the row, for a range
---@return string
function M.title(kind, what, row)
  local words = kind == "range" and ("line %d"):format(row) or SCOPE_WORDS[kind]
  return ("Lex · %s · %s"):format(words, what)
end

--- The scope for the row under the cursor in a buffer: the range when the
--- row has links, else the whole file.
---@param buf integer
---@param row integer
---@return lex.Scope|nil
function M.scope_at(buf, row)
  local st = marks.state(buf)
  if not st then
    return nil
  end
  if marks.count_at(buf, row) > 0 then
    return { kind = "range", repo = st.repo, rel = st.file, buf = buf, row = row, title = M.title("range", vim.fs.basename(st.file), row) }
  end
  return { kind = "file", repo = st.repo, rel = st.file, buf = buf, title = M.title("file", st.file) }
end

--- The scope for a path from the explorer.
---@param path string absolute
---@param is_dir boolean
---@return lex.Scope
function M.scope_for(path, is_dir)
  local repo, root = links.roots(path)
  local rel = require("lex.place").relative(vim.uv.fs_realpath(path) or path, root)
  if is_dir then
    return { kind = "folder", repo = repo, rel = rel, title = M.title("folder", rel == "." and "/" or rel .. "/") }
  end
  local buf = vim.fn.bufnr(path)
  return { kind = "file", repo = repo, rel = rel, buf = buf ~= -1 and buf or nil, title = M.title("file", rel) }
end

--- Everything in the repository the buffer belongs to.
---@param buf? integer
---@return lex.Scope|nil
function M.scope_repo(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local repo = select(1, marks.file_of(buf))
  if not repo then
    repo = links.roots(vim.fn.getcwd())
  end
  return { kind = "repo", repo = repo, title = M.title("repo", vim.fs.basename(repo)) }
end

-- ── the right-click menu ───────────────────────────────────────────────────

--- The picker that owns a buffer, when it is a Lex one.
---@param buf integer
---@return table|nil
function M.owner(buf)
  if vim.bo[buf].filetype ~= "snacks_picker_list" then
    return nil
  end
  for _, p in ipairs(Snacks.picker.get({ source = "lex" })) do
    if p.list.win.buf == buf then
      return p
    end
  end
  return nil
end

--- The row under the mouse, not `picker:current()`: snacks syncs its own row
--- index from a CursorMoved that runs after MenuPopup, so while the menu is
--- being built its idea of the current row is one click behind.
---@param picker table
---@return lex.Item|nil
function M.clicked(picker)
  local win = picker.list.win.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local item = picker.list:get(picker.list:row2idx(cursor - view.topline + 1))
  return item and picker:resolve(item) or nil
end

--- What the right-click menu should offer on the clicked row.
---@param buf integer
---@return { name: string, action: string }[]
function M.menu(buf)
  local picker = M.owner(buf)
  local item = picker and M.clicked(picker)
  if not item then
    return {}
  end
  local items = {
    { name = "💬 Go to the agent", action = "open" },
    { name = "📄 Go to the lines", action = "go" },
    { name = "🗑 Forget this conversation", action = "forget" },
  }
  if #item.conv.places > 1 and #item.here == 1 then
    items[#items + 1] = { name = "🗑 Forget only this place", action = "forget_place" }
  end
  return items
end

--- Run one of the menu's actions on the row under the mouse.
---@param action "open"|"go"|"forget"|"forget_place"
function M.menu_action(action)
  local buf = vim.api.nvim_get_current_buf()
  local picker = M.owner(buf)
  local item = picker and M.clicked(picker)
  local scope = last_scope
  if not item or not scope then
    return
  end
  if action == "open" then
    picker:close()
    return require("lex.open").open(item.conv.newest)
  elseif action == "go" then
    picker:close()
    return M.go_to(item.here[1] or item.conv.newest, scope)
  end
  picker:close()
  if M.forget(item, scope, action == "forget_place") then
    vim.schedule(function()
      M.pick(scope)
    end)
  end
end

return M
