from pathlib import Path

mux_path = Path("cmux-tui/crates/cmux-tui-core/src/mux.rs")
surface_path = Path("cmux-tui/crates/cmux-tui-core/src/surface.rs")

mux = mux_path.read_text()
anchor = """    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test(
"""
helper = r'''    #[cfg(all(test, unix))]
    pub(crate) fn seed_launching_terminal_for_test(
        &self,
        terminal_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-launching-terminal",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )?;
        Ok(())
    }

'''
count = mux.count(anchor)
if count != 1:
    raise SystemExit(f"Mux launching fixture anchor: expected 1 match, found {count}")
mux_path.write_text(mux.replace(anchor, helper + anchor, 1))

surface = surface_path.read_text()
old = r'''        let mux = Mux::new_for_test("hosted-input-ack-reader", SurfaceOptions::default());
        let (attachment, mut host) =
            crate::terminal_host_runtime::input_ack_surface_fixture();
        let surface = Surface::spawn_hosted(
'''
new = r'''        let mux = Mux::new_for_test("hosted-input-ack-reader", SurfaceOptions::default());
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (mut attachment, mut host) =
            crate::terminal_host_runtime::input_ack_surface_fixture();
        let terminal_id = attachment.record.terminal_id.clone();
        attachment.record.workspace_key = workspace.key.clone();
        mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
        let surface = Surface::spawn_hosted(
'''
count = surface.count(old)
if count != 1:
    raise SystemExit(f"Surface durable fixture anchor: expected 1 match, found {count}")
surface_path.write_text(surface.replace(old, new, 1))
