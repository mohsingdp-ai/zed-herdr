# Herdr for Zed (POC)

Zed stays the editor. Herdr owns workspaces, tabs, panes, PTYs, persistence and agent status.
This extension gives Zed's **Agent panel** a `herdr` MCP server that drives the real `herdr` CLI/socket.
Nothing is re-implemented: every call is a `herdr …` command against the running Herdr server.

## What works

| Need | How |
|---|---|
| Show workspaces/tabs/panes + real status | `herdr_status` (from `herdr api snapshot`) — git branch per workspace, working / blocked / done / idle / unknown |
| Create workspace / tab | `herdr_workspace_create`, `herdr_tab_create` |
| Split / close / focus | `herdr_pane_split`, `herdr_close`, `herdr_focus` |
| Launch Claude Code / Codex / … | `herdr_agent_launch` (uses `herdr agent start`, any Herdr-supported kind) |
| Talk to agents | `herdr_agent_prompt` (optional wait), `herdr_read`, `herdr_agent_keys` (answer blocked dialogs) |
| Reconnect after Zed restart | Server is stateless; each call reads live Herdr state |
| Agents outlive Zed | They run in the Herdr server, not in Zed |
| Real PTY inside Zed | Run `herdr` or `herdr agent attach <name>` in Zed's own terminal (see below) |

## Files

```
extension.toml          manifest, declares context server "herdr"
Cargo.toml              wasm crate (zed_extension_api 0.7.0)
src/lib.rs              writes the bundled server to the work dir, launches it with Zed's Node
server/herdr-mcp.mjs    MCP stdio server (Node stdlib only), wraps the herdr CLI
server/smoke-test.mjs   end-to-end check against a throwaway Herdr session
```

## Setup

1. Rust wasm target (Zed compiles dev extensions itself):
   - Arch system Rust: `sudo pacman -S rust-wasm`
   - or rustup: `rustup target add wasm32-wasip2`
2. Zed → command palette → `zed: install dev extension` → pick this folder.
   (Headless alternative: `cargo build --release --target wasm32-wasip2`, copy the wasm to
   `extension.wasm` here, and symlink this folder into `~/.local/share/zed/extensions/installed/herdr`.)
3. Agent panel → settings → turn on the `herdr` MCP server.
   Optional, in `settings.json`:
   ```json
   "context_servers": { "herdr": { "settings": { "session": "", "herdr_path": "" } } }
   ```
   Empty `session` = Herdr's default session. Set `herdr_path` if Zed's PATH lacks `herdr`.
   Per-project override goes in `<project>/.zed/settings.json`. New panes/agents default to the project root.
4. Ask the agent: *"show herdr status"*, *"launch codex named fixer in a new tab of w1 at /path/to/repo"*.

Optional live terminal (Zed user config, not part of the extension) — `~/.config/zed/tasks.json`:
```json
[{ "label": "herdr: attach", "command": "herdr", "use_new_terminal": false, "allow_concurrent_runs": false, "reveal": "always" }]
```
Run with `task: spawn`. This is Herdr's real TUI and PTYs, rendered by Zed's terminal.

## New Claude / OpenCode sessions from Zed run in Herdr

Not doable from the extension (it can't hook Zed's terminal). Done in the shell launcher
`~/.claude/zed-autoresume.sh` (`claude()` in Zed terminals):

- Typing `claude` or `opencode` in a Zed terminal thread starts it in a new tab of that Zed project's Herdr
  workspace (one workspace per Zed project, tagged `zd_project=<root>`, created on first use),
  then `herdr agent attach` shows that live PTY in the Zed thread.
- Closing the Zed thread (Zed still open) closes its Herdr pane.
  Quitting/restarting Zed keeps the agent running in Herdr. The threads Zed restores
  reattach to that project's running agents (first come; the thread title then follows its agent).
- Renaming a Zed thread renames its Herdr pane (read from Zed's sidebar DB each 0.2s).
- Quitting Claude closes the Herdr pane and the Zed view.
- The Zed thread title (sidebar name) mirrors Herdr status: `✘ blocked · …`, `✓ done · …`, `◯ idle · …`, and while working a spinning braille `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` (10 frames, 5 fps) directly before the agent's title.
  Pushed live from Herdr's socket event stream (`events.subscribe`), no polling. Needs `socat` and `jq`.
- Falls back to plain local `claude` when no Herdr server is running. `CZR_HERDR=0` turns it off.
- `claude -c` / `--resume` / `-p` still run locally (unchanged pass-through).

## Check

```sh
herdr --session zedpoc server &      # throwaway session, never touches your default one
node server/smoke-test.mjs           # prints "ok"
herdr --session zedpoc server stop
```

## Known limitations

- **No Herdr view inside Zed's UI.** Extensions cannot add panels, sidebars, status-bar items,
  commands, or terminals. All interaction goes through the Agent panel (Zed Agent; external ACP
  agents only if Zed forwards MCP servers to them).
- **Status is pull, not push.** It refreshes when the agent calls `herdr_status`. No live badges.
- **Slash commands skipped.** Zed 1.18 no longer surfaces text threads, where they ran.
- **Focus of a plain shell pane** focuses its tab (Herdr has no "focus pane by id" CLI).
- **Live PTY needs a manual step:** extension can't open a Zed terminal, so the user runs `herdr` /
  `herdr agent attach` there (or the task above).
- One Herdr session per Zed settings scope; remote `--machine` not exposed.
- `herdr_close` kills processes inside the target; the agent should confirm first.

## Smallest Zed API change needed for embedded Herdr PTYs

Zed already has the whole pipeline (task → terminal panel with a real PTY). Extensions just can't reach it.

1. **Smallest (manifest only, no WIT change):** let extensions ship global tasks, e.g.
   `[[tasks]] label = "herdr: attach" command = "herdr"` in `extension.toml`, loaded like a user
   `tasks.json`. Gives one-keystroke live Herdr in Zed.
2. **For per-pane/agent attach (dynamic IDs):** one host import plus command registration:
   ```wit
   interface terminal {
       record spawn { label: string, command: string, args: list<string>, cwd: option<string>, env: env-vars }
       spawn-in-terminal: func(spec: spawn) -> result<_, string>;
   }
   // extension.toml: [commands.attach-agent] label = "Herdr: Attach Agent"
   export run-command: func(name: string, args: list<string>) -> result<_, string>;
   ```
   The extension resolves `w1:p3` → `herdr agent attach w1:p3` and Zed opens it in a terminal tab.
3. **For a real sidebar with live badges:** a panel/tree-view API plus a way to push updates
   (Herdr already exposes events on its socket). Largest change; not needed for 1–2.
