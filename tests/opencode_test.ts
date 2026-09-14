// Tests for agents/opencode/index.ts. Run: bun run tests/opencode_test.ts
//
// The plugin is called the way OpenCode calls it: the factory with the
// plugin input, then `chat.message` with the parts. The records are compared
// with contract/records.json, so the TypeScript writer and the Lua writer
// must agree on every field, hashes included.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const tmp = mkdtempSync(join(tmpdir(), "lex-"));
let checks = 0;
let failed = 0;

function eq(got: unknown, want: unknown, what: string): void {
  checks++;
  const g = JSON.stringify(got);
  const w = JSON.stringify(want);
  if (g !== w) {
    failed++;
    console.log(`FAIL ${what}\n  got:  ${g}\n  want: ${w}`);
  }
}

type Rec = Record<string, unknown>;

function slug(repo: string): string {
  let readable = repo.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "repo";
  if (readable.length > 48) readable = readable.slice(-48);
  return `${readable}--${createHash("sha256").update(repo).digest("hex").slice(0, 16)}`;
}

function records(home: string): Rec[] {
  const all: Rec[] = [];
  if (!existsSync(home)) return all;
  for (const dir of readdirSync(home)) {
    const file = join(home, dir, "links.jsonl");
    if (!existsSync(file)) continue;
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (line !== "") all.push(JSON.parse(line));
    }
  }
  all.sort((a, b) => (a.repo as string).localeCompare(b.repo as string) || (a.index as number) - (b.index as number));
  return all;
}

const SESSION_FIELDS = ["at", "agent", "session", "pid", "pane", "transcript", "cwd"];
const ORDER = ["repo", "path", "file", "dir", "from", "to", "lang", "index", "of", "body", "head", "tail", "hash", "prompt"];

/** The place part of a record, keys in the contract's order, so JSON compares. */
function placePart(r: Rec): Rec {
  const out: Rec = {};
  for (const k of ORDER) if (r[k] !== undefined && !SESSION_FIELDS.includes(k)) out[k] = r[k];
  return out;
}

const prompt = readFileSync(join(root, "contract/prompt.txt"), "utf8");
const want = (JSON.parse(readFileSync(join(root, "contract/records.json"), "utf8")) as Rec[]).map(placePart);

process.env.TMUX_PANE = "%212";
const mod = await import(join(root, "agents/opencode/index.ts"));
const exported = Object.keys(mod);
eq(exported, ["default"], "the module exports only the plugin");

const directory = "/Users/lukas/Projects/aaa/.worktrees/lukas-44";
const hooks = await mod.default({ directory, worktree: "/Users/lukas/Projects/aaa" });
eq(typeof hooks["chat.message"], "function", "the plugin has chat.message");

async function send(home: string, text: string, sessionID = "ses_7c3e1a"): Promise<void> {
  process.env.LEX_HOME = home;
  await hooks["chat.message"]({ sessionID, agent: "build" }, { message: {}, parts: [{ type: "text", text }] });
}

// the contract prompt
let home = join(tmp, "one");
await send(home, prompt);
let got = records(home);
eq(got.length, 5, "five records");
eq(got.map(placePart), want, "the records match contract/records.json");
for (const [i, r] of got.entries()) {
  eq(r.agent, "opencode", `record ${i} agent`);
  eq(r.session, "ses_7c3e1a", `record ${i} session`);
  eq(r.cwd, directory, `record ${i} cwd`);
  eq(r.pane, "%212", `record ${i} pane`);
  eq(r.pid, process.pid, `record ${i} pid`);
  eq(r.transcript, undefined, `record ${i} has no transcript`);
  eq(typeof r.at === "number" && Math.abs((r.at as number) - Date.now() / 1000) < 60, true, `record ${i} at`);
}
eq(readdirSync(home).sort(), [slug("/Users/lukas/Projects/aaa"), slug("/Users/lukas/Projects/other"), "sessions"].sort(), "one collision-resistant folder per repository, plus the sessions folder");
eq(slug("/a-b/c") === slug("/a/b-c"), false, "colliding readable paths have different hashes");
eq(existsSync(join(home, "hook.log")), false, "no hook.log");

// a second prompt appends
await send(home, prompt);
eq(records(home).length, 10, "a second prompt appends");

// several text parts are one prompt; a file part is ignored
home = join(tmp, "parts");
process.env.LEX_HOME = home;
await hooks["chat.message"](
  { sessionID: "ses_x" },
  {
    message: {},
    parts: [
      { type: "text", text: "Look here:" },
      { type: "file", url: "file:///x" },
      { type: "text", text: '<lex-place path="/r/x.ts" repo="/r" file="x.ts"/>' },
    ],
  },
);
got = records(home);
eq(got.length, 1, "parts: one record");
eq(got[0].prompt, "Look here:", "parts: the prompt line comes from the first text part");

// the session state: working on a message, idle on session.idle
function stateOf(h: string, id: string): Rec | undefined {
  const file = join(h, "sessions", `${id}.json`);
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : undefined;
}
let st = stateOf(join(tmp, "one"), "ses_7c3e1a");
eq([st?.state, st?.agent, st?.pid, st?.pane, st?.cwd], ["working", "opencode", process.pid, "%212", directory], "state: working after the message");
process.env.LEX_HOME = join(tmp, "one");
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_7c3e1a" } } });
eq(stateOf(join(tmp, "one"), "ses_7c3e1a")?.state, "idle", "state: idle after session.idle");
await hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_7c3e1a" } } });
eq(stateOf(join(tmp, "one"), "ses_7c3e1a")?.state, "idle", "state: other events change nothing");
eq(records(join(tmp, "one")).length, 10, "state: no record written by an event");
await hooks.dispose();
eq(stateOf(join(tmp, "one"), "ses_7c3e1a")?.state, "ended", "state: ended when the server goes away");

// nothing to do
home = join(tmp, "none");
await send(home, "just a question");
eq(records(home).length, 0, "no places: no links written");
eq(stateOf(home, "ses_7c3e1a")?.state, "working", "no places: the state is still written");
await send(home, "");
eq(records(home).length, 0, "empty: nothing written");
process.env.LEX_HOME = home;
await hooks["chat.message"]({ sessionID: "ses_x" }, { message: {}, parts: [] });
eq(records(home).length, 0, "no parts: nothing written");
await hooks["chat.message"]({ sessionID: "../evil" }, { message: {}, parts: [{ type: "text", text: "x" }] });
eq(existsSync(join(tmp, "evil.json")), false, "a session id with a slash writes nothing");

// outside tmux
delete process.env.TMUX_PANE;
home = join(tmp, "nopane");
await send(home, prompt);
eq(records(home)[0].pane, undefined, "no tmux: pane absent");

// the caps: 200 code points
home = join(tmp, "caps");
const long = "é".repeat(300);
await send(home, `<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\n  ${long}  \n</lex-place>\n${long}`);
got = records(home);
eq([...(got[0].head as string)].length, 200, "cap: head is 200 characters");
eq([...(got[0].prompt as string)].length, 200, "cap: prompt is 200 characters");

// before/after: read from the file when it still says what the body says
home = join(tmp, "ctx");
const ctx = join(tmp, "ctxrepo");
mkdirSync(ctx, { recursive: true });
const ten = Array.from({ length: 10 }, (_, i) => `line${i + 1}`);
writeFileSync(join(ctx, "file.lua"), ten.join("\n") + "\n");
writeFileSync(join(ctx, "crlf.lua"), ten.join("\r\n") + "\r\n");
const block = (file: string, from: number, to: number, body: string) =>
  `<lex-place path="${ctx}/${file}" repo="${ctx}" file="${file}" lines="${from}-${to}">\n${body}\n</lex-place>`;
await send(
  home,
  [
    block("file.lua", 4, 6, "line4\nline5\nline6"),
    block("file.lua", 1, 2, "line1\nline2"),
    block("file.lua", 9, 10, "line9\nline10"),
    block("file.lua", 4, 6, "changed"),
    block("crlf.lua", 4, 6, "line4\nline5\nline6"),
    block("missing.lua", 4, 6, "line4\nline5\nline6"),
    "why?",
  ].join("\n"),
);
got = records(home);
eq(got.length, 6, "context: six records");
eq([got[0].body, got[0].before, got[0].after], ["line4\nline5\nline6", "line2\nline3", "line7\nline8"], "context: middle of the file");
eq([got[1].before, got[1].after], [undefined, "line3\nline4"], "context: at the top, no before");
eq([got[2].before, got[2].after], ["line7\nline8", undefined], "context: at the end, no after");
eq([got[3].body, got[3].before, got[3].after], ["changed", undefined, undefined], "context: the file moved on, body kept, no context");
eq([got[4].before, got[4].after], ["line2\nline3", "line7\nline8"], "context: a CRLF file still matches");
eq([got[5].body, got[5].before, got[5].after], ["line4\nline5\nline6", undefined, undefined], "context: a missing file, body kept, no context");

// the hash vectors
home = join(tmp, "fnv");
await send(
  home,
  [
    '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\na\n</lex-place>',
    '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-1">\nfoo bar\n</lex-place>',
    '<lex-place path="/r/x.ts" repo="/r" file="x.ts" lines="1-2">\n \n\t\n</lex-place>',
  ].join("\n"),
);
got = records(home);
eq(got.map((r) => r.hash), ["e40c292c", "bf9cf968", "811c9dc5"], "fnv: a, foobar (whitespace removed), empty");
eq([got[2].head, got[2].tail], [undefined, undefined], "fnv: a blank body has no head and no tail");

// the plugin never throws: a broken output object is logged, not raised
home = join(tmp, "throws");
process.env.LEX_HOME = home;
await hooks["chat.message"]({ sessionID: "ses_x" }, { message: {}, parts: null as unknown as [] });
eq(existsSync(join(home, "hook.log")), true, "an error lands in hook.log");

rmSync(tmp, { recursive: true, force: true });
console.log(`${checks} checks, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
