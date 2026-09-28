// Speaks MCP over stdio to herdr-mcp.mjs against a throwaway Herdr session.
// Usage: herdr --session zedpoc server &   then   node server/smoke-test.mjs
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import assert from "node:assert/strict";

const srv = spawn(process.execPath, [new URL("./herdr-mcp.mjs", import.meta.url).pathname], {
  env: { ...process.env, HERDR_ZED_SESSION: process.env.HERDR_ZED_SESSION || "zedpoc" },
});
let buf = "", next = 1;
const waiting = new Map();
srv.stdout.on("data", (d) => {
  buf += d;
  for (let i; (i = buf.indexOf("\n")) >= 0; buf = buf.slice(i + 1)) {
    const m = JSON.parse(buf.slice(0, i));
    waiting.get(m.id)?.(m);
  }
});
const rpc = (method, params) => new Promise((res) => {
  const id = next++;
  waiting.set(id, res);
  srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
});
const call = async (name, args = {}) => {
  const r = (await rpc("tools/call", { name, arguments: args })).result;
  assert.equal(r.isError, false, `${name}: ${r.content[0].text}`);
  return r.content[0].text;
};

assert.equal((await rpc("initialize", { protocolVersion: "2025-06-18" })).result.serverInfo.name, "herdr");
assert.ok((await rpc("tools/list")).result.tools.length >= 8);

const ws = JSON.parse(await call("herdr_workspace_create", { cwd: "/tmp", label: "smoke" }));
const root = ws.root_pane.pane_id;
const split = JSON.parse(await call("herdr_pane_split", { pane: root, direction: "down", cwd: "/tmp" }));
const pane = split.pane.pane_id;
assert.match(await call("herdr_status"), new RegExp(`${pane}\\s+shell`));
await call("herdr_focus", { id: pane });
await call("herdr_close", { id: pane });
assert.doesNotMatch(await call("herdr_status"), new RegExp(`${pane}\\s`));
await call("herdr_close", { id: ws.workspace.workspace_id });

const repo = mkdtempSync("/tmp/herdr-zed-smoke-");
execFileSync("git", ["-C", repo, "init", "-b", "main"]);
const repoWs = JSON.parse(await call("herdr_workspace_create", { cwd: repo, label: "smoke-repo" }));
assert.match(
  await call("herdr_status"),
  new RegExp(`${repoWs.workspace.workspace_id} "smoke-repo" \\[[a-z]+\\] main`)
);
await call("herdr_close", { id: repoWs.workspace.workspace_id });
rmSync(repo, { recursive: true, force: true });

const bad = (await rpc("tools/call", { name: "herdr_close", arguments: { id: "w999:p9" } })).result;
assert.equal(bad.isError, true);
console.log("ok");
srv.kill();
