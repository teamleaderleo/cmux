#![cfg(unix)]

use std::fs;
use std::path::Path;

use cmux_tui_core::WorkspaceRegistry;

fn copy_tree(source: &Path, destination: &Path) {
    fs::create_dir_all(destination).unwrap();
    for entry in fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&source_path).unwrap();
        if metadata.is_dir() {
            copy_tree(&source_path, &destination_path);
        } else if metadata.is_file() {
            fs::copy(&source_path, &destination_path).unwrap();
        }
    }
}

#[test]
fn copied_workspace_state_root_preserves_machine_and_session_identity() {
    let source_root = tempfile::tempdir().unwrap();
    let source_state = source_root.path().join("state");
    let source = WorkspaceRegistry::open(&source_state, "cloud").unwrap();
    let source_machine = source.machine_id().clone();
    let source_session = source.session_id().clone();
    drop(source);

    // Same-machine restart control: CMUX intentionally preserves both identities.
    let restarted = WorkspaceRegistry::open(&source_state, "cloud").unwrap();
    assert_eq!(restarted.machine_id(), &source_machine);
    assert_eq!(restarted.session_id(), &source_session);
    drop(restarted);

    // Models a provider snapshot copied into a separately tracked VM.
    let fork_root = tempfile::tempdir().unwrap();
    let fork_state = fork_root.path().join("state");
    copy_tree(&source_state, &fork_state);
    let fork = WorkspaceRegistry::open(&fork_state, "cloud").unwrap();

    assert_eq!(
        fork.machine_id(),
        &source_machine,
        "copied state did not preserve the durable machine identity"
    );
    assert_eq!(
        fork.session_id(),
        &source_session,
        "copied state did not preserve the durable session identity"
    );
    drop(fork);

    // Fresh-machine control: a new state root receives independent identities.
    let fresh_root = tempfile::tempdir().unwrap();
    let fresh = WorkspaceRegistry::open(fresh_root.path().join("state"), "cloud").unwrap();
    assert_ne!(fresh.machine_id(), &source_machine);
    assert_ne!(fresh.session_id(), &source_session);
}
