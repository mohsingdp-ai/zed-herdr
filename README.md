# Herdr for Zed (POC)

Zed stays the editor. Herdr owns workspaces, tabs, panes and agents.
This extension gives Zed's Agent panel a `herdr` MCP server that drives the real `herdr` CLI.

## Tools

- `herdr_status` — workspaces, tabs, panes, git branch, agent status
- `herdr_workspace_create`, `herdr_tab_create` — create workspace / tab
- `herdr_pane_split`, `herdr_close`, `herdr_focus` — manage panes
- `herdr_agent_launch` — launch Claude Code, Codex, ...
- `herdr_agent_prompt`, `herdr_read`, `herdr_agent_keys` — talk to agents

Stateless: every call reads live state. Agents run in Herdr, so they outlive Zed.

## Setup

1. `rustup target add wasm32-wasip2`
2. Zed → command palette → `zed: install dev extension` → pick this folder.
3. Agent panel → settings → enable `herdr`.
4. Ask: "show herdr status".

Optional `settings.json`:
```json
"context_servers": { "herdr": { "settings": { "session": "", "herdr_path": "" } } }
```

Empty `session` = default session. Set `herdr_path` if Zed's PATH lacks `herdr`.

## Check

```sh
herdr --session zedpoc server &   # throwaway session
node server/smoke-test.mjs        # prints "ok"
herdr --session zedpoc server stop
```

## Limits

- No Herdr UI inside Zed (extensions can't add panels or terminals) — use the Agent panel.
- Status is pull, not push.
- Live PTY: run `herdr` or `herdr agent attach <name>` in Zed's terminal.
- `herdr_close` kills processes inside the pane — confirm first.
