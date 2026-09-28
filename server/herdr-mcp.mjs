// Herdr MCP server for Zed. Stdlib only; runs on Zed's bundled Node.
// Stateless: every call asks the Herdr server over its CLI/socket, so it
// reconnects for free after Zed restarts and never owns any PTY.
import { execFile } from "node:child_process";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";

const BIN = process.env.HERDR_ZED_BIN || "herdr";
const SESSION = process.env.HERDR_ZED_SESSION || "";
const base = SESSION ? ["--session", SESSION] : [];

export function herdr(args) {
  return new Promise((resolve) => {
    execFile(BIN, [...base, ...args], { maxBuffer: 32 << 20, timeout: 330_000 }, (err, stdout, stderr) => {
      if (err && err.code === "ENOENT") return resolve({ error: `herdr binary not found: ${BIN}` });
      const text = (err ? stderr || err.message : stdout).trim();
      let json;
      try { json = JSON.parse(text); } catch { json = null; }
      if (err || json?.error) return resolve({ error: json?.error ? `${json.error.code}: ${json.error.message}` : text });
      resolve({ result: json ? json.result : text });
    });
  });
}

const attachCmd = (target) => ["herdr", ...base, ...(target ? ["agent", "attach", target] : [])].join(" ");

function git(cwd, args) {
  return new Promise((resolve) => {
    execFile("git", ["-C", cwd, ...args], { timeout: 5000 }, (err, stdout) => {
      resolve(err ? null : stdout.trim() || null);
    });
  });
}

async function workspaceBranch(snap, workspaceId) {
  const pane = snap.panes.find((p) => p.workspace_id === workspaceId);
  const cwd = pane?.cwd || pane?.foreground_cwd;
  if (!cwd) return null;
  const name = await git(cwd, ["symbolic-ref", "--short", "-q", "HEAD"]);
  if (name) return name;
  const head = await git(cwd, ["rev-parse", "--verify", "-q", "HEAD"]);
  return head ? await git(cwd, ["rev-parse", "--short", "HEAD"]) : null;
}

export async function renderStatus(snap) {
  const agents = new Map(snap.agents.map((a) => [a.pane_id, a]));
  const out = [`herdr ${snap.version} session=${SESSION || "default"}`];
  if (!snap.workspaces.length) out.push("(no workspaces)");
  for (const w of snap.workspaces) {
    const f = w.workspace_id === snap.focused_workspace_id ? " *focused" : "";
    const branch = await workspaceBranch(snap, w.workspace_id);
    out.push(`${w.workspace_id} "${w.label}" [${w.agent_status}]${branch ? ` ${branch}` : ""}${f}`);
    for (const t of snap.tabs.filter((t) => t.workspace_id === w.workspace_id)) {
      out.push(`  ${t.tab_id} "${t.label}" [${t.agent_status}]`);
      for (const p of snap.panes.filter((p) => p.tab_id === t.tab_id)) {
        const a = agents.get(p.pane_id);
        const who = a ? `${a.agent}${a.name ? ` "${a.name}"` : ""} ${a.agent_status}` : "shell";
        const title = a?.terminal_title_stripped ? ` — ${a.terminal_title_stripped}` : "";
        out.push(`    ${p.pane_id}  ${who}  ${p.foreground_cwd || p.cwd}${title}${p.pane_id === snap.focused_pane_id ? " *focused" : ""}`);
      }
    }
  }
  out.push("", `Live terminal in Zed: run \`${attachCmd()}\` (whole session) or \`${attachCmd("<agent-name>")}\` in Zed's terminal.`);
  return out.join("\n");
}

const kindOf = (id) => (/:p/.test(id) ? "pane" : /:t/.test(id) ? "tab" : "workspace");
const opt = (flag, v) => (v ? [flag, String(v)] : []);
const cwd = (a) => ["--cwd", a.cwd || process.cwd()]; // Zed starts us in the project root
const str = (description) => ({ type: "string", description });

const tools = {
  herdr_status: {
    description:
      "List Herdr workspaces (with the git branch of their working directory, when it is inside a repository), tabs and panes with live agent status (working / blocked / done / idle / unknown).",
    schema: {},
    async run() {
      const r = await herdr(["api", "snapshot"]);
      return r.error ? r : { result: await renderStatus(r.result.snapshot) };
    },
  },
  herdr_workspace_create: {
    description: "Create a Herdr workspace (does not steal focus).",
    schema: { cwd: str("Absolute working directory (default: Zed project root)"), label: str("Workspace label") },
    run: (a) => herdr(["workspace", "create", "--no-focus", ...cwd(a), ...opt("--label", a.label)]),
  },
  herdr_tab_create: {
    description: "Create a tab in a Herdr workspace.",
    schema: { workspace: str("Workspace id, e.g. w1"), cwd: str("Absolute working directory (default: Zed project root)"), label: str("Tab label") },
    required: ["workspace"],
    run: (a) => herdr(["tab", "create", "--no-focus", "--workspace", a.workspace, ...cwd(a), ...opt("--label", a.label)]),
  },
  herdr_pane_split: {
    description: "Split a Herdr pane, creating a new shell pane next to it.",
    schema: { pane: str("Pane id to split, e.g. w1:p1"), direction: { type: "string", enum: ["right", "down"] }, cwd: str("Absolute working directory (default: Zed project root)") },
    required: ["pane"],
    run: (a) => herdr(["pane", "split", a.pane, "--no-focus", "--direction", a.direction || "right", ...cwd(a)]),
  },
  herdr_close: {
    description: "Close a Herdr pane, tab or workspace by id. Kills the processes inside it.",
    schema: { id: str("Pane (w1:p2), tab (w1:t1) or workspace (w1) id") },
    required: ["id"],
    run: (a) => herdr([kindOf(a.id), "close", a.id]),
  },
  herdr_focus: {
    description: "Focus a Herdr workspace, tab, or agent pane in attached Herdr clients. A plain shell pane focuses its tab.",
    schema: { id: str("Pane, tab or workspace id, or a live agent name") },
    required: ["id"],
    async run(a) {
      const kind = kindOf(a.id);
      if (kind !== "pane") return herdr([kind, "focus", a.id]);
      const r = await herdr(["agent", "focus", a.id]);
      if (!r.error) return r;
      const p = await herdr(["pane", "get", a.id]);
      return p.error ? p : herdr(["tab", "focus", p.result.pane.tab_id]);
    },
  },
  herdr_agent_launch: {
    description:
      "Start any coding agent Herdr supports in Herdr. Uses the given shell pane, else a new tab in `workspace`, else a new workspace. The agent keeps running in Herdr after Zed exits.",
    schema: {
      kind: str("Agent kind (herdr 0.9.1): pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, qwen, letta, maki, muse"),
      name: str("Unique agent name matching [a-z][a-z0-9_-]{0,31}"),
      pane: str("Existing idle shell pane id"),
      workspace: str("Workspace id to add a tab to when no pane is given"),
      cwd: str("Absolute working directory for a new tab/workspace (default: Zed project root)"),
      args: { type: "array", items: { type: "string" }, description: "Extra native agent CLI args" },
    },
    required: ["kind", "name"],
    async run(a) {
      let pane = a.pane;
      if (!pane) {
        const r = a.workspace
          ? await herdr(["tab", "create", "--no-focus", "--workspace", a.workspace, "--label", a.name, ...cwd(a)])
          : await herdr(["workspace", "create", "--no-focus", "--label", a.name, ...cwd(a)]);
        if (r.error) return r;
        pane = r.result.root_pane.pane_id;
      }
      const extra = a.args?.length ? ["--", ...a.args] : [];
      return herdr(["agent", "start", a.name, "--kind", a.kind, "--pane", pane, ...extra]);
    },
  },
  herdr_agent_prompt: {
    description: "Send a prompt to a Herdr agent. With wait=true, block until it is idle, done or blocked.",
    schema: { target: str("Agent name or pane id"), text: str("Prompt text"), wait: { type: "boolean" } },
    required: ["target", "text"],
    run: (a) => herdr(["agent", "prompt", a.target, a.text, ...(a.wait ? ["--wait", "--timeout", "300000"] : [])]),
  },
  herdr_read: {
    description: "Read recent terminal output from a Herdr pane id or agent name.",
    schema: { target: str("Pane id (w1:p1) or agent name"), lines: { type: "integer", description: "Rows to read (default 80)" } },
    required: ["target"],
    run: (a) => herdr([/:p/.test(a.target) ? "pane" : "agent", "read", a.target, "--source", "recent-unwrapped", "--lines", String(a.lines || 80)]),
  },
  herdr_agent_keys: {
    description: "Send key presses to a Herdr agent, e.g. to answer a blocked approval dialog. Read the screen first and ask the user before approving anything.",
    schema: { target: str("Agent name or pane id"), keys: { type: "array", items: { type: "string" }, description: "Keys like enter, esc, up, down, tab, ctrl+c, y" } },
    required: ["target", "keys"],
    run: (a) => herdr(["agent", "send-keys", a.target, ...a.keys]),
  },
};

export async function handle(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case "initialize":
      return {
        protocolVersion: params?.protocolVersion || "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "herdr", version: "0.1.0" },
      };
    case "ping":
      return {};
    case "tools/list":
      return {
        tools: Object.entries(tools).map(([name, t]) => ({
          name,
          description: t.description,
          inputSchema: { type: "object", properties: t.schema, required: t.required || [] },
        })),
      };
    case "tools/call": {
      const t = tools[params?.name];
      if (!t) throw { code: -32602, message: `unknown tool ${params?.name}` };
      const r = await t.run(params.arguments || {});
      const text = r.error ?? (typeof r.result === "string" ? r.result : JSON.stringify(r.result, null, 2));
      return { content: [{ type: "text", text }], isError: !!r.error };
    }
    default:
      if (id === undefined) return undefined; // notification
      throw { code: -32601, message: `method not found: ${method}` };
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const send = (m) => process.stdout.write(JSON.stringify(m) + "\n");
  createInterface({ input: process.stdin }).on("line", async (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }); }
    try {
      const result = await handle(msg);
      if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, result });
    } catch (e) {
      if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, error: { code: e.code || -32603, message: e.message || String(e) } });
    }
  });
}
