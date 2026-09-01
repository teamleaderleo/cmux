#![cfg(unix)]

use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use cmux_remote::crypto::{
    AuthKind, AuthRequest, InboundAuthEvidence, NetworkPeer, ServerAuthenticator, StaticIdentity,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote_protocol::{Lane, SessionId};
use cmux_tui_core::WorkspaceRegistry;

fn request(
    mode: AuthKind,
    invitation_id: Option<String>,
    client: &StaticIdentity,
) -> AuthRequest {
    AuthRequest {
        mode,
        invitation_id,
        device_public_key: client.public_key(),
        device_name: "materialization-test-device".into(),
        session: SessionId([11; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation: 0,
        inbound: InboundAuthEvidence::Network(NetworkPeer::Tcp),
    }
}

async fn enroll_device(state: &std::path::Path) -> (String, StaticIdentity, String) {
    let database = AuthDatabase::load_or_create(state, "source", false).unwrap();
    let client = StaticIdentity::generate().unwrap();
    let invitation = database
        .create_invitation(Duration::from_secs(60), Vec::new())
        .await
        .unwrap();
    let waiter = {
        let database = Arc::clone(&database);
        let request = request(AuthKind::Invitation, Some(invitation.id.clone()), &client);
        tokio::spawn(async move { database.authorize(request).await })
    };
    let pending = database.wait_for_pending(Duration::from_secs(2)).await.unwrap();
    assert_eq!(pending.len(), 1);
    let enrolled = database.approve(&invitation.id).await.unwrap();
    waiter.await.unwrap().unwrap();
    let fingerprint = database.identity().fingerprint();
    database.shutdown().await.unwrap();
    drop(database);
    (fingerprint, client, enrolled.id)
}

fn materialize(
    workspace_state: &std::path::Path,
    remote_state: &std::path::Path,
    materialization_id: &str,
    inherit_enrollments: bool,
) -> serde_json::Value {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .arg("__materialize-new-machine")
        .arg("--workspace-state-root")
        .arg(workspace_state)
        .arg("--remote-state-dir")
        .arg(remote_state)
        .arg("--materialization-id")
        .arg(materialization_id);
    if inherit_enrollments {
        command.arg("--inherit-enrollments");
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "materialization failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn wait_for_committed_marker(path: &std::path::Path, child: &mut std::process::Child) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(data) = std::fs::read(path)
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data)
            && value["phase"] == "committed"
        {
            return;
        }
        if let Some(status) = child.try_wait().unwrap() {
            panic!("cmux-tui server exited before materialization committed: {status}");
        }
        assert!(Instant::now() < deadline, "timed out waiting for materialization marker");
        thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn materialization_help_does_not_require_or_mutate_state() {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["__materialize-new-machine", "--help"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("__materialize-new-machine"));
    assert!(stdout.contains("--materialization-id"));
}

#[tokio::test]
async fn fresh_materialization_rotates_machine_and_daemon_identity_once() {
    let workspace_root = tempfile::tempdir().unwrap();
    let workspace_state = workspace_root.path().join("workspace-state");
    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    let source_machine = registry.machine_id().clone();
    let source_session = registry.session_id().clone();
    drop(registry);

    let remote_root = tempfile::tempdir().unwrap();
    let remote_state = remote_root.path().join("remote-state");
    let (source_fingerprint, client, enrolled_id) = enroll_device(&remote_state).await;

    let first = materialize(&workspace_state, &remote_state, "cloud-vm-b", false);
    assert_eq!(first["changed"], true);

    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    let first_machine = registry.machine_id().clone();
    assert_ne!(first_machine, source_machine);
    assert_eq!(registry.session_id(), &source_session);
    drop(registry);

    let database = AuthDatabase::load_or_create(&remote_state, "copy", false).unwrap();
    let first_fingerprint = database.identity().fingerprint();
    assert_ne!(first_fingerprint, source_fingerprint);
    assert!(!database.device_is_active(&enrolled_id).await);
    assert!(
        database
            .authorize(request(AuthKind::Enrolled, None, &client))
            .await
            .is_err()
    );
    database.shutdown().await.unwrap();
    drop(database);

    let replay = materialize(&workspace_state, &remote_state, "cloud-vm-b", false);
    assert_eq!(replay["changed"], false);
    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    assert_eq!(registry.machine_id(), &first_machine);
    assert_eq!(registry.session_id(), &source_session);
    drop(registry);
    let database = AuthDatabase::load_or_create(&remote_state, "copy", false).unwrap();
    assert_eq!(database.identity().fingerprint(), first_fingerprint);
    database.shutdown().await.unwrap();
    drop(database);

    let next = materialize(&workspace_state, &remote_state, "cloud-vm-c", false);
    assert_eq!(next["changed"], true);
    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    assert_ne!(registry.machine_id(), &first_machine);
    assert_eq!(registry.session_id(), &source_session);
    drop(registry);
    let database = AuthDatabase::load_or_create(&remote_state, "copy", false).unwrap();
    assert_ne!(database.identity().fingerprint(), first_fingerprint);
    database.shutdown().await.unwrap();
}

#[tokio::test]
async fn inherited_enrollment_is_explicit_and_keeps_device_authority() {
    let workspace_root = tempfile::tempdir().unwrap();
    let workspace_state = workspace_root.path().join("workspace-state");
    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    let source_machine = registry.machine_id().clone();
    let source_session = registry.session_id().clone();
    drop(registry);

    let remote_root = tempfile::tempdir().unwrap();
    let remote_state = remote_root.path().join("remote-state");
    let (source_fingerprint, client, enrolled_id) = enroll_device(&remote_state).await;

    let result = materialize(&workspace_state, &remote_state, "cloud-vm-inherit", true);
    assert_eq!(result["changed"], true);
    assert_eq!(result["enrollment_policy"], "inherit");

    let registry = WorkspaceRegistry::open(&workspace_state, "main").unwrap();
    assert_ne!(registry.machine_id(), &source_machine);
    assert_eq!(registry.session_id(), &source_session);
    drop(registry);

    let database = AuthDatabase::load_or_create(&remote_state, "copy", false).unwrap();
    assert_ne!(database.identity().fingerprint(), source_fingerprint);
    assert!(database.device_is_active(&enrolled_id).await);
    let grant = database
        .authorize(request(AuthKind::Enrolled, None, &client))
        .await
        .expect("explicit inherited-enrollment policy should retain copied device authority");
    assert_eq!(grant.device_id, enrolled_id);
    database.shutdown().await.unwrap();
}

#[tokio::test]
async fn cloud_create_token_rekeys_before_server_start_opens_copied_state() {
    let home = tempfile::tempdir().unwrap();
    let state_home = home.path().join(".local").join("state");
    let workspace_state = state_home.join("cmux-tui").join("sessions");
    let remote_state = state_home.join("cmux").join("remote");

    let registry = WorkspaceRegistry::open(&workspace_state, "cloud").unwrap();
    let source_machine = registry.machine_id().clone();
    let source_session = registry.session_id().clone();
    drop(registry);
    let (source_fingerprint, client, enrolled_id) = enroll_device(&remote_state).await;

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["server", "start", "--session", "cloud"])
        .env("HOME", home.path())
        .env_remove("XDG_STATE_HOME")
        .env("CMUX_TUI_MATERIALIZATION_ID", "provider-create-token")
        .env("TERM", "xterm-256color")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let marker = workspace_state.join("cloud-materialization.json");
    wait_for_committed_marker(&marker, &mut child);
    child.kill().unwrap();
    let _ = child.wait().unwrap();

    let registry = WorkspaceRegistry::open(&workspace_state, "cloud").unwrap();
    assert_ne!(registry.machine_id(), &source_machine);
    assert_eq!(registry.session_id(), &source_session);
    drop(registry);

    let database = AuthDatabase::load_or_create(&remote_state, "copy", false).unwrap();
    assert_ne!(database.identity().fingerprint(), source_fingerprint);
    assert!(!database.device_is_active(&enrolled_id).await);
    assert!(
        database
            .authorize(request(AuthKind::Enrolled, None, &client))
            .await
            .is_err()
    );
    database.shutdown().await.unwrap();
}
