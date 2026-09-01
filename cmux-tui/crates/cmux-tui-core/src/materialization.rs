//! Offline machine-identity transition for snapshot materialization.
//!
//! A copied workspace state root intentionally preserves session history, but a
//! newly tracked machine needs a new root-level [`MachinePublicId`]. This helper
//! owns only that root identity file; session SQLite databases remain untouched.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

use anyhow::Context;
use fs4::FileExt;

use crate::platform;
use crate::resource::MachinePublicId;

const MACHINE_ID_FILE: &str = "machine-id";
const MACHINE_ID_LOCK_FILE: &str = "machine-id.lock";

/// Install `machine_id` as the root-level durable machine identity.
///
/// This is an offline materialization primitive. It uses the same lock and
/// durability boundary as normal machine-id creation, but replaces an existing
/// identity atomically while leaving every session database untouched.
///
/// The operation refuses if another process currently owns the machine-id lock.
pub fn install_materialized_machine_id(
    root: &Path,
    machine_id: &MachinePublicId,
) -> anyhow::Result<()> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(root)?;

    let lock_path = root.join(MACHINE_ID_LOCK_FILE);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open machine identity lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::try_lock(&lock).with_context(|| {
        format!(
            "machine identity is busy; materialization must run before the cmux owner starts: {}",
            lock_path.display()
        )
    })?;

    let path = root.join(MACHINE_ID_FILE);
    let temporary = root.join(format!(
        ".machine-id.materialize-{}-{:016x}",
        machine_id.as_str(),
        random_u64()?
    ));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .with_context(|| format!("create staged machine identity {}", temporary.display()))?;
        platform::restrict_file(&temporary)?;
        file.write_all(machine_id.as_str().as_bytes())
            .and_then(|()| file.write_all(b"\n"))
            .with_context(|| format!("write staged machine identity {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync staged machine identity {}", temporary.display()))?;
        fs::rename(&temporary, &path).with_context(|| {
            format!(
                "publish materialized machine identity {} -> {}",
                temporary.display(),
                path.display()
            )
        })?;
        platform::restrict_file(&path)?;
        platform::sync_directory(root)
            .with_context(|| format!("sync state root {}", root.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    let _ = FileExt::unlock(&lock);
    result
}

fn random_u64() -> anyhow::Result<u64> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("generate materialization staging suffix: {error}"))?;
    Ok(u64::from_le_bytes(bytes))
}
