use zed_extension_api::{
    self as zed, settings::ContextServerSettings, Command, ContextServerConfiguration,
    ContextServerId, Project, Result,
};

// The MCP server ships inside the wasm and is written to the extension's work dir.
const SERVER_JS: &str = include_str!("../server/herdr-mcp.mjs");

struct Herdr;

impl zed::Extension for Herdr {
    fn new() -> Self {
        Herdr
    }

    fn context_server_command(
        &mut self,
        id: &ContextServerId,
        project: &Project,
    ) -> Result<Command> {
        std::fs::write("herdr-mcp.mjs", SERVER_JS).map_err(|e| e.to_string())?;
        let script = std::env::current_dir()
            .map_err(|e| e.to_string())?
            .join("herdr-mcp.mjs");
        let settings = ContextServerSettings::for_project(id.as_ref(), project)?
            .settings
            .unwrap_or_default();
        let env = [
            ("session", "HERDR_ZED_SESSION"),
            ("herdr_path", "HERDR_ZED_BIN"),
        ]
        .into_iter()
        .filter_map(|(key, var)| Some((var.into(), settings.get(key)?.as_str()?.to_string())))
        .collect();
        Ok(Command {
            command: zed::node_binary_path()?,
            args: vec![script.to_string_lossy().into_owned()],
            env,
        })
    }

    fn context_server_configuration(
        &mut self,
        _id: &ContextServerId,
        _project: &Project,
    ) -> Result<Option<ContextServerConfiguration>> {
        Ok(Some(ContextServerConfiguration {
            installation_instructions: "Needs the `herdr` CLI (0.9+) and a running Herdr server. Leave `session` empty for the default session.".into(),
            settings_schema: r#"{"type":"object","properties":{"session":{"type":"string","description":"Herdr session name (empty = default)"},"herdr_path":{"type":"string","description":"Path to the herdr binary (default: herdr on PATH)"}}}"#.into(),
            default_settings: r#"{"session": "", "herdr_path": ""}"#.into(),
        }))
    }
}

zed::register_extension!(Herdr);
