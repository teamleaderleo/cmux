//! Offline remote-authority transition for snapshot materialization.
//!
//! A copied daemon state directory is valid for resurrection of the same
//! machine, but a newly tracked machine needs an independent Noise identity.
//! This module performs that transition while the daemon is stopped.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::Path;

use anyhow::{Context, bail};
use base64::Engine as _;
use serde_json::{Value, json};

use crate::crypto::StaticIdentity;
use crate::identity::{PersistedAuthStateSchema, persisted_auth_state_schema};
use crate::owner_lock::{OwnerFileLock, sibling_lock_path};
use crate::secure_directory::{DirectoryAccess, ensure_secure_directory};

const IDENTITY_FILE: &str = "identity.json";
const DEVICES_FILE: &str = "devices.json";
const IDENTITY_VERSION: u64 = 1;

/// Policy for authorization records copied from the source machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaterializedEnrollmentPolicy {
    /// New machine, new trust decision. Existing devices and invitations are cleared.
    Fresh,
    /// Preserve copied device authorization while rotating the daemon key.
    Inherit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteMaterializationResult {
    pub daemon_fingerprint: String,
    pub enrollment_policy: MaterializedEnrollmentPolicy,
}

/// Install a new daemon static identity into an offline copied state directory.
///
/// The authorization database lease is acquired before the identity lease, the
/// same ownership order used by [`crate::identity::AuthDatabase`]. If either is
/// live, materialization refuses rather than racing a running daemon.
pub fn install_materialized_daemon_identity(
    state_dir: &Path,
    identity: &StaticIdentity,
    enrollment_policy: MaterializedEnrollmentPolicy,
) -> anyhow::Result<RemoteMaterializationResult> {
    ensure_secure_directory(state_dir, DirectoryAccess::ManagedOwnerOnly)
        .with_context(|| format!("secure remote state directory {}", state_dir.display()))?;

    let devices_path = state_dir.join(DEVICES_FILE);
    let identity_path = state_dir.join(IDENTITY_FILE);
    let devices_lock_path = sibling_lock_path(&devices_path)?;
    let identity_lock_path = sibling_lock_path(&identity_path)?;

    let _devices_lock = OwnerFileLock::try_acquire(&devices_lock_path).with_context(|| {
        format!(
            "remote authorization state is busy; materialization must run before the daemon starts: {}",
            devices_lock_path.display()
        )
    })?;
    let _identity_lock = OwnerFileLock::try_acquire(&identity_lock_path).with_context(|| {
        format!(
            "remote identity is busy; materialization must run before the daemon starts: {}",
            identity_lock_path.display()
        )
    })?;

    if enrollment_policy == MaterializedEnrollmentPolicy::Fresh {
        clear_copied_authorization(state_dir, &devices_path)?;
    }
    write_identity(&identity_path, identity)?;

    Ok(RemoteMaterializationResult {
        daemon_fingerprint: identity.fingerprint(),
        enrollment_policy,
    })
}

fn clear_copied_authorization(state_dir: &Path, devices_path: &Path) -> anyhow::Result<()> {
    match persisted_auth_state_schema(state_dir)? {
        PersistedAuthStateSchema::Missing => return Ok(()),
        PersistedAuthStateSchema::Current => {}
        PersistedAuthStateSchema::Legacy => {
            bail!("copied authorization state is legacy and requires explicit migration before rekey")
        }
        PersistedAuthStateSchema::Unsupported(version) => {
            bail!("copied authorization state version {version} is unsupported")
        }
    }

    let data = fs::read(devices_path)
        .with_context(|| format!("read copied authorization state {}", devices_path.display()))?;
    let mut state: Value = serde_json::from_slice(&data)
        .with_context(|| format!("parse copied authorization state {}", devices_path.display()))?;
    let object = state
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("copied authorization state is not an object"))?;

    object.insert("devices".into(), Value::Array(Vec::new()));
    object.insert("invitations".into(), Value::Array(Vec::new()));
    increment_counter(object, "revision")?;
    increment_counter(object, "revocation_generation")?;
    atomic_json(devices_path, &state)?;
    Ok(())
}

fn increment_counter(
    object: &mut serde_json::Map<String, Value>,
    field: &str,
) -> anyhow::Result<()> {
    let current = object.get(field).and_then(Value::as_u64).unwrap_or(0);
    let next = current
        .checked_add(1)
        .ok_or_else(|| anyhow::anyhow!("{field} exhausted during materialization"))?;
    object.insert(field.into(), Value::Number(next.into()));
    Ok(())
}

fn write_identity(path: &Path, identity: &StaticIdentity) -> anyhow::Result<()> {
    let version = match fs::read(path) {
        Ok(data) => serde_json::from_slice::<Value>(&data)
            .ok()
            .and_then(|value| value.get("version").and_then(Value::as_u64))
            .unwrap_or(IDENTITY_VERSION),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => IDENTITY_VERSION,
        Err(error) => return Err(error).with_context(|| format!("read identity {}", path.display())),
    };
    let private_key = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(identity.private_key());
    atomic_json(path, &json!({ "version": version, "private_key": private_key }))
}

fn atomic_json(path: &Path, value: &Value) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("state path has no parent: {}", path.display()))?;
    ensure_secure_directory(parent, DirectoryAccess::ManagedOwnerOnly)?;

    let mut random = [0_u8; 9];
    getrandom::fill(&mut random).map_err(|error| anyhow::anyhow!(error.to_string()))?;
    let suffix = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random);
    let temporary = parent.join(format!(
        ".{}.materialize-{}-{suffix}",
        path.file_name().and_then(|name| name.to_str()).unwrap_or("state"),
        std::process::id()
    ));
    let data = serde_json::to_vec_pretty(value)?;

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .with_context(|| format!("create staged state {}", temporary.display()))?;
    let result = (|| {
        file.write_all(&data)
            .with_context(|| format!("write staged state {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync staged state {}", temporary.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        }
        fs::rename(&temporary, path).with_context(|| {
            format!("publish staged state {} -> {}", temporary.display(), path.display())
        })?;
        #[cfg(unix)]
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
