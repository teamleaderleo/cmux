#![cfg(unix)]

use std::fs;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::crypto::{
    AuthKind, AuthRequest, InboundAuthEvidence, NetworkPeer, ServerAuthenticator, StaticIdentity,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote_protocol::{Lane, SessionId};

fn request(
    mode: AuthKind,
    invitation_id: Option<String>,
    client: &StaticIdentity,
) -> AuthRequest {
    AuthRequest {
        mode,
        invitation_id,
        device_public_key: client.public_key(),
        device_name: "fieldwork-device".into(),
        session: SessionId([7; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation: 0,
        inbound: InboundAuthEvidence::Network(NetworkPeer::Tcp),
    }
}

#[tokio::test]
async fn copied_auth_database_creates_split_brain_revocation_under_one_daemon_fingerprint() {
    let source_root = tempfile::tempdir().unwrap();
    let source_state = source_root.path().join("auth");
    let source = AuthDatabase::load_or_create(&source_state, "source", false).unwrap();
    let client = StaticIdentity::generate().unwrap();
    let invitation = source
        .create_invitation(Duration::from_secs(60), Vec::new())
        .await
        .unwrap();

    let waiter = {
        let source = Arc::clone(&source);
        let request = request(AuthKind::Invitation, Some(invitation.id.clone()), &client);
        tokio::spawn(async move { source.authorize(request).await })
    };
    let pending = source.wait_for_pending(Duration::from_secs(2)).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].invitation_id, invitation.id);
    let enrolled = source.approve(&invitation.id).await.unwrap();
    let initial_grant = waiter.await.unwrap().unwrap();
    assert_eq!(initial_grant.device_id, enrolled.id);
    assert!(source.device_is_active(&enrolled.id).await);

    let source_fingerprint = source.identity().fingerprint();
    source.shutdown().await.unwrap();
    drop(source);

    // Models the provider snapshot boundary: machine-scoped daemon identity and
    // authorization state are ordinary files copied into the fork's filesystem.
    let fork_root = tempfile::tempdir().unwrap();
    let fork_state = fork_root.path().join("auth");
    fs::create_dir_all(&fork_state).unwrap();
    for name in ["identity.json", "devices.json"] {
        fs::copy(source_state.join(name), fork_state.join(name)).unwrap();
    }

    let source = AuthDatabase::load_or_create(&source_state, "source", false).unwrap();
    let fork = AuthDatabase::load_or_create(&fork_state, "fork", false).unwrap();
    assert_eq!(source.identity().fingerprint(), source_fingerprint);
    assert_eq!(fork.identity().fingerprint(), source_fingerprint);
    assert!(source.device_is_active(&enrolled.id).await);
    assert!(fork.device_is_active(&enrolled.id).await);

    source.revoke(&enrolled.id).await.unwrap();
    assert!(!source.device_is_active(&enrolled.id).await);
    assert!(
        source
            .authorize(request(AuthKind::Enrolled, None, &client))
            .await
            .is_err(),
        "source daemon still authorized the revoked device"
    );

    let fork_grant = fork
        .authorize(request(AuthKind::Enrolled, None, &client))
        .await
        .expect("fork should still accept its independently copied active-device record");
    assert_eq!(fork_grant.device_id, enrolled.id);
    assert_eq!(fork.identity().fingerprint(), source.identity().fingerprint());

    source.shutdown().await.unwrap();
    fork.shutdown().await.unwrap();
}
