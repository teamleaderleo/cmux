#![cfg(unix)]

use std::path::Path;
use std::process::Command;

use cmux_remote::crypto::StaticIdentity;
use cmux_remote::identity::ClientIdentityStore;

const SOURCE_ROUTE: &str = "wss://127.0.0.1:9/v1/link";
const FORK_ROUTE: &str = "wss://127.0.0.1:10/v1/link";
const OTHER_ROUTE: &str = "wss://127.0.0.1:11/v1/link";
const ROUTE_MISS: &str = "no known daemon matches this route; connect with an invitation";

fn connect_stderr(state_root: &Path, route: &str) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["remote", "connect", route, "--state-dir"])
        .arg(state_root)
        .args(["--headless", "--connect-timeout-seconds", "1"])
        .output()
        .expect("run cmux-tui remote connect");
    String::from_utf8_lossy(&output.stderr).into_owned()
}

async fn new_store(root: &Path) -> ClientIdentityStoreHandle {
    let client_root = root.join("client");
    let store = ClientIdentityStore::load_or_create(client_root).expect("create client state");
    ClientIdentityStoreHandle(store)
}

struct ClientIdentityStoreHandle(std::sync::Arc<ClientIdentityStore>);

impl std::ops::Deref for ClientIdentityStoreHandle {
    type Target = ClientIdentityStore;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

#[tokio::test]
async fn cloned_daemon_repin_orphans_source_route_when_another_daemon_is_known() {
    let directory = tempfile::tempdir().unwrap();
    let store = new_store(directory.path()).await;
    let source_key = StaticIdentity::generate().unwrap().public_key();
    let other_key = StaticIdentity::generate().unwrap().public_key();

    let source = store
        .pin_daemon("source".into(), source_key, vec![SOURCE_ROUTE.into()])
        .await
        .unwrap();
    store
        .pin_daemon("other".into(), other_key, vec![OTHER_ROUTE.into()])
        .await
        .unwrap();

    // Models a fork whose snapshotted daemon identity is identical to the source.
    // Enrolling the fork re-pins the same fingerprint at the fork's fresh route.
    let fork = store
        .pin_daemon("fork".into(), source_key, vec![FORK_ROUTE.into()])
        .await
        .unwrap();
    assert_eq!(source.fingerprint, fork.fingerprint);

    let known = store.known_daemons().await;
    let shared = known
        .iter()
        .find(|daemon| daemon.fingerprint == source.fingerprint)
        .expect("shared daemon record disappeared");
    assert_eq!(shared.route_hints, [FORK_ROUTE]);
    assert!(!shared.route_hints.iter().any(|route| route == SOURCE_ROUTE));

    let stderr = connect_stderr(directory.path(), SOURCE_ROUTE);
    assert!(
        stderr.contains(ROUTE_MISS),
        "source route did not fail at the known-daemon identity boundary: {stderr}"
    );
}

#[tokio::test]
async fn distinct_fork_daemon_identity_preserves_source_route_selection() {
    let directory = tempfile::tempdir().unwrap();
    let store = new_store(directory.path()).await;
    let source_key = StaticIdentity::generate().unwrap().public_key();
    let fork_key = StaticIdentity::generate().unwrap().public_key();
    let other_key = StaticIdentity::generate().unwrap().public_key();

    store
        .pin_daemon("source".into(), source_key, vec![SOURCE_ROUTE.into()])
        .await
        .unwrap();
    store
        .pin_daemon("other".into(), other_key, vec![OTHER_ROUTE.into()])
        .await
        .unwrap();
    store
        .pin_daemon("fork".into(), fork_key, vec![FORK_ROUTE.into()])
        .await
        .unwrap();

    let stderr = connect_stderr(directory.path(), SOURCE_ROUTE);
    assert!(
        !stderr.contains(ROUTE_MISS),
        "distinct fork identity unexpectedly orphaned the source route: {stderr}"
    );
}

#[tokio::test]
async fn sole_shared_daemon_uses_the_existing_single_daemon_fallback() {
    let directory = tempfile::tempdir().unwrap();
    let store = new_store(directory.path()).await;
    let source_key = StaticIdentity::generate().unwrap().public_key();

    store
        .pin_daemon("source".into(), source_key, vec![SOURCE_ROUTE.into()])
        .await
        .unwrap();
    store
        .pin_daemon("fork".into(), source_key, vec![FORK_ROUTE.into()])
        .await
        .unwrap();

    let stderr = connect_stderr(directory.path(), SOURCE_ROUTE);
    assert!(
        !stderr.contains(ROUTE_MISS),
        "single-daemon fallback unexpectedly rejected the displaced source route: {stderr}"
    );
}
