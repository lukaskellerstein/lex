// The Lex writer for OpenCode. One file, no imports beyond node's own, so a
// copy into ~/.config/opencode/plugin/ is the whole install.
//
// OpenCode has no hook command to run per prompt. It has a plugin API, and a
// plugin runs inside the opencode process. So where Claude Code and Codex
// start `nvim -l hook.lua` on every prompt, this listens to `chat.message`,
// the call that carries the user's parts before the message is saved, and
// writes the same records to the same store:
//
//   $LEX_HOME/<repo-slug>/links.jsonl      ($LEX_HOME defaults to ~/.lex)
//
// and the same session state file the Lua writer keeps, `working` on
// `chat.message`, `idle` on the `session.idle` event, and `ended` for every
// session this server touched when the server goes away (`dispose`):
//
//   $LEX_HOME/sessions/<session>.json
//
// The parser and the record are a copy of agents/claude-code/hook.lua, in
// TypeScript. `contract/` in the lex repository keeps the two equal: the same
// prompt must give the same records. Change the block there and here, or in
// neither.
//
// `body` is the block's body, byte for byte: the photo of what the session
// saw. The editor finds the lines again from it after the file changed, so
// nothing here is ever updated. `before` and `after` are read from the file
// now, only when its lines still say what the body says.
//
// Differences that come from the host, not from choice:
//
//   agent       "opencode"
//   session     input.sessionID, the `ses_…` id `opencode -s <id>` resumes
//   pid         process.pid, the opencode process the editor asks with kill(pid, 0)
//   pane        $TMUX_PANE as the server inherited it from the TUI; absent when
//               the server was started by hand
//   transcript  absent; OpenCode keeps sessions in SQLite, and the editor runs
//               `opencode export <id>` when it needs the text
//   cwd         the plugin's `directory`
//
// Nothing here may throw. A record is not worth an exception inside the
// agent, so every entry point is wrapped, and an error goes to
// $LEX_HOME/hook.log.

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const TAG = "lex-place";
const CAP = 200;
const CONTEXT = 2;
const WS = "[ \\t\\n\\v\\f\\r]";

type Place = {
  n?: number;
  path: string;
  repo: string;
  file?: string;
  dir?: string;
  from?: number;
  to?: number;
  lang?: string;
  body?: string;
};

// ── the block ──────────────────────────────────────────────────────────────

const UNESC: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"' };

function attrs(s: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of s.matchAll(/([A-Za-z0-9_]+)="([^"]*)"/g)) {
    out[m[1]] = m[2].replace(/&([A-Za-z]+);/g, (all, name) => UNESC[name] ?? all);
  }
  return out;
}

function finish(a: Record<string, string>): Place | undefined {
  let n: number | undefined;
  if (a.n !== undefined) {
    n = Number(a.n);
    if (!Number.isFinite(n)) return undefined;
  }
  if (!(a.path && a.repo && (a.file || a.dir))) return undefined;
  const p: Place = { path: a.path, repo: a.repo };
  if (n !== undefined) p.n = n;
  if (a.dir) p.dir = a.dir;
  else p.file = a.file;
  if (a.lang) p.lang = a.lang;
  return p;
}

/**
 * Every place in a prompt, in order, and the text that is left when the
 * blocks are taken out. A suffixed tag closes only with the same suffix.
 * When both forms match at the same spot the self-closing one wins: the open
 * form would otherwise swallow `<… dir="docs"/>` and everything up to the
 * next closing tag.
 */
function parse(text: string): { places: Place[]; free: string } {
  const places: Place[] = [];
  const free: string[] = [];
  const name = TAG.replace(/-/g, "\\-");
  const open = new RegExp(`<${name}(-?\\d*)(${WS}[^>]*?)>\\n?([\\s\\S]*?)\\n?</${name}\\1>`, "g");
  const empty = new RegExp(`<${name}(-?\\d*)(${WS}[^>]*?)/>`, "g");
  let pos = 0;
  for (;;) {
    open.lastIndex = pos;
    empty.lastIndex = pos;
    const m = open.exec(text);
    const m2 = empty.exec(text);
    if (!m && !m2) break;
    let s: number, e: number;
    let p: Place | undefined;
    if (m2 && (!m || m2.index <= m.index)) {
      s = m2.index;
      e = s + m2[0].length;
      if (m2[1] === "" || /^-\d+$/.test(m2[1])) p = finish(attrs(m2[2]));
    } else {
      const mm = m!;
      s = mm.index;
      e = s + mm[0].length;
      if (mm[1] === "" || /^-\d+$/.test(mm[1])) {
        const a = attrs(mm[2]);
        const lines = /^(\d+)-(\d+)$/.exec(a.lines ?? "");
        const from = lines ? Number(lines[1]) : NaN;
        const to = lines ? Number(lines[2]) : NaN;
        if (a.file && lines && from >= 1 && from <= to) {
          p = finish(a);
          if (p) {
            p.from = from;
            p.to = to;
            p.body = mm[3];
          }
        }
      }
    }
    free.push(text.slice(pos, s));
    if (p) places.push(p);
    pos = e;
  }
  free.push(text.slice(pos));
  return { places, free: free.join("") };
}

// ── what the lines said ────────────────────────────────────────────────────

/** The first CAP characters (code points, not bytes). */
function cap(s: string): string {
  return [...s].slice(0, CAP).join("");
}

const TRIM = new RegExp(`^${WS}+|${WS}+$`, "g");

function trim(s: string): string {
  return s.replace(TRIM, "");
}

/** The first and the last non-blank line of a body, trimmed and capped. */
function headTail(body: string): { head?: string; tail?: string } {
  let head: string | undefined;
  let tail: string | undefined;
  for (const raw of body.split("\n")) {
    const line = trim(raw);
    if (line !== "") {
      head ??= line;
      tail = line;
    }
  }
  return { head: head && cap(head), tail: tail && cap(tail) };
}

/**
 * FNV-1a, 32 bits, over the body with every whitespace character removed,
 * as eight hex digits. The same bytes and the same answer as the Lua writer.
 */
function fnv1a(body: string): string {
  const bytes = new TextEncoder().encode(body.replace(new RegExp(`${WS}+`, "g"), ""));
  let h = 0x811c9dc5;
  for (const b of bytes) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/**
 * Up to CONTEXT raw lines before and after the range, read from the file
 * itself, only when its lines `from`..`to` still equal the body (a trailing
 * CR is ignored). A file that moved on, or is missing, gives no context.
 */
function context(p: Place): { before?: string; after?: string } {
  let text: string;
  try {
    text = readFileSync(p.path, "utf8");
  } catch {
    return {};
  }
  const lines = text.split("\n").map((l) => l.replace(/\r$/, ""));
  // A file that ends with a newline splits into one extra empty string.
  if (text.endsWith("\n")) lines.pop();
  const from = p.from as number;
  const to = p.to as number;
  if (lines.length < to || lines.slice(from - 1, to).join("\n") !== p.body) return {};
  const out: { before?: string; after?: string } = {};
  if (from > 1) out.before = lines.slice(Math.max(0, from - 1 - CONTEXT), from - 1).join("\n");
  if (lines.length > to) out.after = lines.slice(to, Math.min(lines.length, to + CONTEXT)).join("\n");
  return out;
}

/** The first non-blank line of the free text, trimmed and capped. */
function firstLine(free: string): string {
  for (const raw of free.split("\n")) {
    const line = trim(raw);
    if (line !== "") return cap(line);
  }
  return "";
}

// ── the store ──────────────────────────────────────────────────────────────

function home(): string {
  const h = process.env.LEX_HOME;
  return h && h !== "" ? h : join(homedir(), ".lex");
}

function slug(repo: string): string {
  return repo.replace(/[^A-Za-z0-9]/g, "-");
}

function log(msg: string): void {
  try {
    mkdirSync(home(), { recursive: true });
    appendFileSync(join(home(), "hook.log"), `${new Date().toISOString().replace(/\.\d{3}Z$/, "Z")} ${msg}\n`);
  } catch {
    // nothing left to do
  }
}

/** The sessions this server has written a state for, for `dispose`. */
const touched = new Set<string>();

/** The session's state file. One small file, overwritten each time. */
function sessionState(session: string, cwd: string, state: "working" | "idle" | "ended"): void {
  if (!session || /[/\\]/.test(session)) return;
  touched.add(session);
  const dir = join(home(), "sessions");
  mkdirSync(dir, { recursive: true });
  const pane = process.env.TMUX_PANE || undefined;
  writeFileSync(
    join(dir, `${session}.json`),
    JSON.stringify({ state, at: Math.floor(Date.now() / 1000), agent: "opencode", pid: process.pid, pane, cwd }) + "\n",
  );
}

// ── the records ────────────────────────────────────────────────────────────

/** Parse one prompt and append its records. The one job. */
function record(session: string, cwd: string, prompt: string): void {
  const { places, free } = parse(prompt);
  if (places.length === 0) return;

  const at = Math.floor(Date.now() / 1000);
  const pane = process.env.TMUX_PANE || undefined;
  const line = firstLine(free);

  const byRepo = new Map<string, string[]>();
  places.forEach((p, i) => {
    const r: Record<string, unknown> = {
      at,
      agent: "opencode",
      session,
      pid: process.pid,
      pane,
      cwd,
      repo: p.repo,
      path: p.path,
      index: p.n ?? i + 1,
      of: places.length,
      prompt: line,
    };
    if (p.dir) {
      r.dir = p.dir;
    } else {
      r.file = p.file;
      if (p.from !== undefined) {
        r.from = p.from;
        r.to = p.to;
        if (p.lang) r.lang = p.lang;
        r.body = p.body ?? "";
        const ctx = context(p);
        r.before = ctx.before;
        r.after = ctx.after;
        const ht = headTail(p.body ?? "");
        r.head = ht.head;
        r.tail = ht.tail;
        r.hash = fnv1a(p.body ?? "");
      }
    }
    const lines = byRepo.get(p.repo) ?? [];
    lines.push(JSON.stringify(r));
    byRepo.set(p.repo, lines);
  });

  for (const [repo, lines] of byRepo) {
    const dir = join(home(), slug(repo));
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, "links.jsonl"), lines.join("\n") + "\n");
  }
}

// ── the plugin ─────────────────────────────────────────────────────────────

type ChatMessageInput = { sessionID: string; agent?: string };
type ChatMessageOutput = { parts: { type: string; text?: string }[] };
type EventInput = { event: { type: string; properties?: { sessionID?: string } } };

/**
 * The one export. OpenCode loads what a plugin file exports as plugins (the
 * agent-inbox plugin in mac-setup exports its factory both named and as the
 * default), so the helpers above stay private rather than risk being called
 * as factories; the tests go through this entry point too.
 */
const LexPlugin = async ({ directory }: { directory: string }) => ({
  "chat.message": async (input: ChatMessageInput, output: ChatMessageOutput): Promise<void> => {
    try {
      sessionState(input.sessionID, directory, "working");
      const text = output.parts
        .filter((p) => p.type === "text" && typeof p.text === "string")
        .map((p) => p.text as string)
        .join("\n");
      record(input.sessionID, directory, text);
    } catch (e) {
      log(`error: ${e instanceof Error ? e.message : String(e)}`);
    }
  },
  event: async ({ event }: EventInput): Promise<void> => {
    try {
      if (event.type === "session.idle" && event.properties?.sessionID) {
        sessionState(event.properties.sessionID, directory, "idle");
      }
    } catch (e) {
      log(`error: ${e instanceof Error ? e.message : String(e)}`);
    }
  },
  dispose: async (): Promise<void> => {
    try {
      for (const id of touched) sessionState(id, directory, "ended");
    } catch (e) {
      log(`error: ${e instanceof Error ? e.message : String(e)}`);
    }
  },
});

export default LexPlugin;
