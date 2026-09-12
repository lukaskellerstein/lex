-- Lex marks: the visual prototype, second round (PLAN.md, step 2).
--
-- The look is decided (2026-09-11): a line wash and a sign bar on every row of
-- a linked range, and a `💬 N` badge at the end of its first row. No underline.
-- The cursor inside a range expands the badge with the newest prompt and its
-- age. Where two ranges overlap, the wash is one tone deeper and the sign
-- column shows two bars. A running session says `working…` in green.
--
-- This file paints fake links over a sample buffer so the rules can be seen
-- under the real theme. The rules here are the ones lex.nvim will implement.
--
-- Use:
--   :luafile prototype/marks.lua
--   :LexProto ts|py|md|yaml|sh     open a sample buffer of that type and paint it
--   :LexProto                      paint the current buffer (needs 50 lines)
--   :LexProtoWash                  wash on or off, for reading
--   :LexProtoWhole                 add or remove a whole-file place: a bar on
--                                  every row, no wash, a badge on row 1
--   :LexProtoPending               add or remove a pending place on rows 15-18,
--                                  over history: blue wins the rows, `▎┆`
--   :LexProtoOff                   remove everything
--
-- The fake links (rows are fixed, so any sample shows every case):
--   6-16   two conversations on one range
--   14-19  a second range that overlaps the first on rows 14-16
--   26-31  a session that is working now
--   33-47  a long range, with 36-38 nested inside it
--
-- Tune the palette at the top and run :luafile again.

local M = {}

-- Palette. Against vscode.nvim's Normal bg #1F1F1F.
--
-- lex: a marker yellow, the product color. Not blue: Visual is blue in this
-- theme. Not green: git add and the explorer's worktree wash are green. It is
-- also clear of the two yellows already on screen, git modified #E2C08D (a
-- tan, low saturation) and DiagnosticWarn #CCA700 (darker, olive).
--
-- tone[n]: the wash under a row that n ranges cover. Each step is the same
-- yellow-ward shift again, so overlap reads as a second stroke of the marker.
--
-- running: Rex's --ok green. A state color, not the product color.
local P = {
  lex = "#EACB4A",
  tone = { "#2F2C1B", "#3D381F", "#4B4423" },
  running = "#66AD93",
  running_bg = "#1F2B27",
  -- pending: copied, not yet sent. Rex's --link blue, your selection. The
  -- bar is dashed and the badge has no fill, so shape differs as well as hue.
  sel = "#8FB4F0",
  sel_bg = "#232B36",
  dim = "#6E6E6E",
  icon = "💬", -- an emoji keeps its own colors; a Nerd Font glyph would take `lex`
  -- The wash can be turned off for reading. Bars and badges stay, so the
  -- links are still there, only quieter. :LexProtoWash flips it.
  wash = true,
}

local ns = vim.api.nvim_create_namespace("lex_proto")
local ns_badge = vim.api.nvim_create_namespace("lex_proto_badge")
local group = vim.api.nvim_create_augroup("lex_proto", { clear = true })

local function highlights()
  local set = vim.api.nvim_set_hl
  for i, bg in ipairs(P.tone) do
    set(0, "LexProtoWash" .. i, { bg = bg })
  end
  set(0, "LexProtoSign", { fg = P.lex })
  set(0, "LexProtoBadge", { fg = P.lex, bg = P.tone[2], bold = true })
  set(0, "LexProtoBadgeText", { fg = P.dim, bg = P.tone[2], italic = true })
  set(0, "LexProtoWorking", { fg = P.running, bg = P.running_bg, bold = true })
  set(0, "LexProtoPendSign", { fg = P.sel })
  set(0, "LexProtoPendWash", { bg = P.sel_bg })
  set(0, "LexProtoPendBadge", { fg = P.sel, bold = true })
end

-- One entry per conversation. Rows are 1-based and inclusive, like `lines`.
local LINKS = {
  { session = "f357503d", from = 6, to = 16, age = "2h", prompt = "Why does login retry twice?" },
  { session = "a91c0e77", from = 6, to = 16, age = "3d", prompt = "Extract the retry into a helper" },
  { session = "0b7d2f10", from = 14, to = 19, age = "1d", prompt = "Is `throw last` right after the loop?" },
  { session = "c4e8a5b2", from = 26, to = 31, age = "12m", prompt = "Refresh before expiry, not after", working = true },
  { session = "7d13f9aa", from = 33, to = 47, age = "5d", prompt = "Make the store observable" },
  { session = "e2a6c081", from = 36, to = 38, age = "6h", prompt = "Return a copy from get()" },
}

-- A whole-file place, toggled by :LexProtoWhole. It adds a lane in the sign
-- column on every row and a badge on row 1, and no wash: Rex's rule, a
-- document is outlined, never filled. A folder place above the file looks
-- the same; only the badge text differs ("folder docs/").
local WHOLE = false

-- A pending place, toggled by :LexProtoPending: copied, not yet sent. Rows
-- 15-18, on purpose on top of two history ranges. The rule where phases
-- meet: the background belongs to the most recent phase, the bars and the
-- badges show every phase. So the rows go blue, the sign is `▎┆` in blue
-- (one sign per slot, one color per sign), and the `💬` badges stay.
local PENDING = false
local PEND_FROM, PEND_TO = 15, 18

--- Group the links by range. One badge per range, however many sessions.
---@return { from: number, to: number, links: table[], working: boolean }[]
local function ranges()
  local by, order = {}, {}
  for _, l in ipairs(LINKS) do
    local key = l.from .. "-" .. l.to
    if not by[key] then
      by[key] = { from = l.from, to = l.to, links = {}, working = false }
      order[#order + 1] = by[key]
    end
    table.insert(by[key].links, l)
    by[key].working = by[key].working or l.working or false
  end
  return order
end

--- The static layer: wash and bars, one extmark pair per row.
local function paint_static(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  local cover = {}
  for _, r in ipairs(ranges()) do
    for row = r.from, math.min(r.to, total) do
      cover[row] = (cover[row] or 0) + 1
    end
  end
  for row = 1, total do
    local n = cover[row] or 0
    -- The wash counts ranges only. A whole-file place adds a lane, not a tone.
    local lanes = n + (WHOLE and 1 or 0)
    local pending = PENDING and row >= PEND_FROM and row <= PEND_TO
    if lanes > 0 or pending then
      local wash = (P.wash and pending) and "LexProtoPendWash"
        or (P.wash and n > 0) and ("LexProtoWash" .. math.min(n, #P.tone))
        or nil
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        line_hl_group = wash,
        -- Two cells is the sign limit: one bar, or two where places overlap.
        -- A pending place takes the sign in blue; the past keeps the wash.
        sign_text = pending and (lanes > 0 and "▎┆" or "┆") or (lanes >= 2 and "▎▎" or "▎"),
        sign_hl_group = pending and "LexProtoPendSign" or "LexProtoSign",
        -- Below diagnostics (10), so a warning on the row still wins the slot.
        priority = 5,
        strict = false,
      })
    end
  end
end

--- The badge layer, redrawn on every cursor move: `💬 N` at rest, and the
--- newest prompt and its age while the cursor stands inside the range. No
--- virtual line, so nothing moves under the cursor.
local function paint_badges(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_badge, 0, -1)
  local total = vim.api.nvim_buf_line_count(buf)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for _, r in ipairs(ranges()) do
    if r.from <= total then
      local inside = cur >= r.from and cur <= r.to
      local chunks = { { " " .. P.icon .. " " .. #r.links .. " ", "LexProtoBadge" } }
      if inside then
        local newest = r.links[1]
        chunks[#chunks + 1] = { " " .. newest.prompt .. "  ·  " .. newest.age .. " ", "LexProtoBadgeText" }
      end
      if r.working then
        chunks[#chunks + 1] = { " working… ", "LexProtoWorking" }
      end
      vim.api.nvim_buf_set_extmark(buf, ns_badge, r.from - 1, 0, {
        virt_text = chunks,
        virt_text_pos = "eol_right_align",
        priority = 20,
        strict = false,
      })
    end
  end
  if WHOLE then
    vim.api.nvim_buf_set_extmark(buf, ns_badge, 0, 0, {
      virt_text = { { " " .. P.icon .. " 1 ", "LexProtoBadge" }, { " whole file ", "LexProtoBadgeText" } },
      virt_text_pos = "eol_right_align",
      priority = 20,
      strict = false,
    })
  end
  if PENDING and PEND_FROM <= total then
    vim.api.nvim_buf_set_extmark(buf, ns_badge, PEND_FROM - 1, 0, {
      virt_text = { { " 📌 1 ", "LexProtoPendBadge" } },
      virt_text_pos = "eol_right_align",
      priority = 21,
      strict = false,
    })
  end
end

local function paint(buf)
  M.off(buf)
  highlights()
  paint_static(buf)
  paint_badges(buf)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      paint_badges(buf)
    end,
  })
end

function M.off(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_badge, 0, -1)
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
end

--- Wash on or off, repainted in place. The badge layer keeps its cursor state.
function M.toggle_wash()
  P.wash = not P.wash
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  paint_static(buf)
  Snacks.notify.info("Lex wash " .. (P.wash and "on" or "off"))
end

function M.toggle_whole()
  WHOLE = not WHOLE
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  paint_static(buf)
  paint_badges(buf)
  Snacks.notify.info("Lex whole-file place " .. (WHOLE and "on" or "off"))
end

function M.toggle_pending()
  PENDING = not PENDING
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  paint_static(buf)
  paint_badges(buf)
  Snacks.notify.info("Lex pending place " .. (PENDING and "on: rows 15-18, copied, not sent, over history" or "off"))
end

-- Sample buffers, one per filetype, all at least 50 lines.
local SAMPLES = {}

SAMPLES.ts = [[
import { api } from "./api"
import type { User, Session } from "./types"

const MAX_RETRIES = 2

export async function login(user: User): Promise<Session> {
  let last: unknown
  for (let i = 0; i <= MAX_RETRIES; i++) {
    try {
      return await api.login(user)
    } catch (err) {
      last = err
    }
  }
  throw last
}

export function logout(session: Session) {
  return api.logout(session.token)
}

export function isExpired(session: Session, now = Date.now()) {
  return session.expiresAt <= now
}

export async function refresh(session: Session): Promise<Session> {
  if (!isExpired(session)) {
    return session
  }
  return api.refresh(session.token)
}

export class SessionStore {
  private current: Session | null = null

  get(): Session | null {
    return this.current
  }

  set(session: Session) {
    this.current = session
  }

  clear() {
    this.current = null
  }
}

export const store = new SessionStore()

export async function ensure(user: User): Promise<Session> {
  const s = store.get()
  if (s && !isExpired(s)) return s
  const fresh = s ? await refresh(s) : await login(user)
  store.set(fresh)
  return fresh
}
]]

SAMPLES.py = [[
from __future__ import annotations

import time
from dataclasses import dataclass

MAX_RETRIES = 2


@dataclass
class Session:
    token: str
    expires_at: float

    def expired(self, now: float | None = None) -> bool:
        return self.expires_at <= (now or time.time())


class Api:
    def login(self, user: str) -> Session:
        raise NotImplementedError

    def refresh(self, token: str) -> Session:
        raise NotImplementedError

    def logout(self, token: str) -> None:
        raise NotImplementedError


api = Api()


def login(user: str) -> Session:
    last: Exception | None = None
    for _ in range(MAX_RETRIES + 1):
        try:
            return api.login(user)
        except Exception as err:  # noqa: BLE001
            last = err
    assert last is not None
    raise last


def refresh(session: Session) -> Session:
    if not session.expired():
        return session
    return api.refresh(session.token)


def ensure(user: str, current: Session | None) -> Session:
    if current and not current.expired():
        return current
    return refresh(current) if current else login(user)
]]

SAMPLES.md = [[
# Auth

The login flow, and why it retries.

## Overview

`login()` asks the API for a session. The API answers with a token and an
expiry time. The token goes into the session store.

## Retries

The API drops about one call in fifty during a deploy. So `login()` tries
up to three times before it gives up. Two retries, not more: a third one
adds a second of delay and almost never helps.

## Refresh

A session expires. `refresh()` checks the expiry first and returns the
session unchanged when it is still valid, so callers can call it freely.

## Store

One store per process. `ensure()` is the only function most callers need:

1. Take the current session from the store.
2. If it is valid, return it.
3. If it is expired, refresh it.
4. If there is none, log in.

## Open questions

- Should a refresh failure fall back to a full login?
- Is a two-retry limit still right after the gateway change?
- Where does the expiry clock skew get handled?

## History

The retry loop was added on 2026-03-02 after the gateway deploy incident.
Before that, one failed call logged the user out.

## See also

- `src/api.ts`
- `docs/gateway.md`

## Glossary

- **session**: a token and an expiry time, one per logged-in user.
- **refresh**: a new session from an old token, without a password.
- **gateway**: the proxy in front of the API that drops calls during a deploy.
]]

SAMPLES.yaml = [[
name: auth
version: 3

api:
  base_url: https://api.example.com
  timeout_ms: 5000
  retries: 2

session:
  ttl_seconds: 3600
  refresh_before_seconds: 300
  store: memory

logging:
  level: info
  format: json
  fields:
    - request_id
    - user_id
    - duration_ms

features:
  refresh: true
  logout_everywhere: false
  remember_me: true

limits:
  login_per_minute: 10
  refresh_per_minute: 60
  concurrent_sessions: 5

gateway:
  host: gw.internal
  port: 8443
  tls:
    verify: true
    ca_file: /etc/ssl/gw-ca.pem

alerts:
  login_failure_rate:
    threshold: 0.05
    window_seconds: 300
  refresh_latency_ms:
    threshold: 800
    window_seconds: 60

owners:
  - team: platform
    channel: "#auth"
]]

SAMPLES.sh = [[
#!/usr/bin/env bash
set -euo pipefail

MAX_RETRIES=2
API=${API:-https://api.example.com}

login() {
  local user=$1 i
  for ((i = 0; i <= MAX_RETRIES; i++)); do
    if curl -fsS -X POST "$API/login" -d "user=$user"; then
      return 0
    fi
  done
  echo "login failed after $((MAX_RETRIES + 1)) tries" >&2
  return 1
}

logout() {
  local token=$1
  curl -fsS -X POST "$API/logout" -H "Authorization: Bearer $token"
}

refresh() {
  local token=$1
  curl -fsS -X POST "$API/refresh" -H "Authorization: Bearer $token"
}

expired() {
  local expires_at=$1 now
  now=$(date +%s)
  [ "$expires_at" -le "$now" ]
}

ensure() {
  local user=$1 token=${2:-} expires_at=${3:-0}
  if [ -n "$token" ] && ! expired "$expires_at"; then
    echo "$token"
    return 0
  fi
  if [ -n "$token" ]; then
    refresh "$token"
  else
    login "$user"
  fi
}

case "${1:-}" in
  login) login "$2" ;;
  logout) logout "$2" ;;
  refresh) refresh "$2" ;;
  ensure) ensure "$2" "${3:-}" "${4:-0}" ;;
  *) echo "usage: auth.sh login|logout|refresh|ensure" >&2; exit 2 ;;
esac
]]

local FT = { ts = "typescript", py = "python", md = "markdown", yaml = "yaml", sh = "sh" }

function M.show(kind)
  local buf
  if kind and kind ~= "" then
    local text = SAMPLES[kind]
    if not text then
      return Snacks.notify.error("Unknown sample: " .. kind .. ". Use ts, py, md, yaml or sh")
    end
    vim.cmd("enew")
    buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modified = false
    vim.api.nvim_buf_set_name(buf, "lex-proto-auth." .. kind)
    vim.bo[buf].filetype = FT[kind]
  else
    buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_line_count(buf) < 50 then
      return Snacks.notify.warn("This buffer has fewer than 50 lines. Try :LexProto ts")
    end
  end
  paint(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  Snacks.notify.info("Lex prototype painted. Move the cursor into a marked range. :LexProtoOff to clear")
end

vim.api.nvim_create_user_command("LexProto", function(a)
  M.show(a.args)
end, {
  nargs = "?",
  complete = function()
    return { "ts", "py", "md", "yaml", "sh" }
  end,
})
vim.api.nvim_create_user_command("LexProtoOff", function()
  M.off()
end, {})
vim.api.nvim_create_user_command("LexProtoWash", function()
  M.toggle_wash()
end, {})
vim.api.nvim_create_user_command("LexProtoWhole", function()
  M.toggle_whole()
end, {})
vim.api.nvim_create_user_command("LexProtoPending", function()
  M.toggle_pending()
end, {})

return M
