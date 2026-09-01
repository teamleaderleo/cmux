#![cfg(unix)]

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use base64::Engine as _;
use cmux_remote::crypto::StaticIdentity;
use cmux_remote::materialization::{
    MaterializedEnrollmentPolicy, install_materialized_daemon_identity,
};
use cmux_tui_core::materialization::install_materialized_machine_id;
use cmux_tui_core::resource::MachinePublicId;
use fs4::FileExt;
use serde::{Deserialize, Serialize};

const MARKER_FILE: &str = "cloud-materialization.json";
const MARKER_LOCK_FILE: &str = "cloud-materialization.lock";
const USAGE: &str = "usage: cmux-tui __materialize-new-machine --workspace-state-root <path> --remote-state-dir <path> --materialization-id <id> [--inherit-enrollments]";

#[derive(Debug)]
struct Args {
    workspace_state_root: PathBuf,
    remote_state_dir: PathBuf,
    materialization_id: String,
    enrollment_policy: MaterializedEnrollmentPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MaterializationMarker {
    version: u32,
    phase: String,
    materialization_id: String,
    machine_id: String,
    daemon_fingerprint: String,
    enrollment_policy: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    daemon_private_key: Option<String>,
}

/// Private Cloud lifecycle mode invoked before `server start` on a copied VM.
///
/// This deliberately lives outside the public resource/remote CLI. Only the
/// Cloud control plane needs to distinguish "same machine resurrected" from
/// "copied state is becoming a new machine".
pub fn run(raw_args: &[String]) -> i32 {
    if raw_args.iter().any(|arg| matches!(arg.as_str(), "--help" | "-h")) {
        println!("{USAGE}");
        return 0;
    }
    match run_inner(raw_args) {
        Ok(()) => 0,
        Err(error) => {
            crate::client_log::stderr_log!(
                "materialization",
                "cmux-tui materialize-new-machine: {error:#}"
            );
            1
        }
    }
}

fn run_inner(raw_args: &[String]) -> anyhow::Result<()> {
    let args = parse_args(raw_args)?;
    validate_materialization_id(&args.materialization_id)?;
    fs::create_dir_all(&args.workspace_state_root).with_context(|| {
        format!("create workspace state root {}", args.workspace_state_root.display())
    })?;
    cmux_tui_core::platform::restrict_directory(&args.workspace_state_root)?;

    let lock_path = args.workspace_state_root.join(MARKER_LOCK_FILE);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open materialization lock {}", lock_path.display()))?;
    cmux_tui_core::platform::restrict_file(&lock_path)?;
    FileExt::try_lock(&lock)
        .with_context(|| format!("another materialization owns {}", lock_path.display()))?;

    let result = materialize_under_lock(&args);
    let _ = FileExt::unlock(&lock);
    result
}

fn materialize_under_lock(args: &Args) -> anyhow::Result<()> {
    let marker_path = args.workspace_state_root.join(MARKER_FILE);
    let marker = match read_marker(&marker_path)? {
        Some(marker)
            if marker.materialization_id == args.materialization_id && marker.phase == "committed" =>
        {
            print_receipt(false, &marker);
            return Ok(());
        }
        Some(marker)
            if marker.materialization_id == args.materialization_id && marker.phase == "pending" =>
        {
            marker
        }
        Some(marker) if marker.phase == "pending" => {
            bail!(
                "materialization {} is still pending; refusing to replace it with {}",
                marker.materialization_id,
                args.materialization_id
            )
        }
        _ => prepare_marker(&marker_path, args)?,
    };

    let private_key = marker
        .daemon_private_key
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("pending materialization marker has no daemon key"))?;
    let private_key = decode_private_key(private_key)?;
    let identity = StaticIdentity::from_private(private_key);
    if identity.fingerprint() != marker.daemon_fingerprint {
        bail!("pending materialization marker daemon key does not match its fingerprint");
    }
    let machine_id = MachinePublicId::parse(&marker.machine_id)
        .context("pending materialization marker has an invalid machine id")?;
    let enrollment_policy = parse_policy(&marker.enrollment_policy)?;

    // Auth state first: its owner lease is held for the daemon lifetime, so a
    // running daemon makes this fail closed before the root machine id changes.
    install_materialized_daemon_identity(&args.remote_state_dir, &identity, enrollment_policy)?;
    install_materialized_machine_id(&args.workspace_state_root, &machine_id)?;

    let committed = MaterializationMarker {
        version: marker.version,
        phase: "committed".into(),
        materialization_id: marker.materialization_id,
        machine_id: marker.machine_id,
        daemon_fingerprint: marker.daemon_fingerprint,
        enrollment_policy: marker.enrollment_policy,
        daemon_private_key: None,
    };
    atomic_marker(&marker_path, &committed)?;
    print_receipt(true, &committed);
    Ok(())
}

fn parse_args(raw_args: &[String]) -> anyhow::Result<Args> {
    let mut workspace_state_root = None;
    let mut remote_state_dir = None;
    let mut materialization_id = None;
    let mut enrollment_policy = MaterializedEnrollmentPolicy::Fresh;
    let mut index = 0;
    while index < raw_args.len() {
        match raw_args[index].as_str() {
            "--workspace-state-root" => {
                index += 1;
                workspace_state_root = raw_args.get(index).map(PathBuf::from);
            }
            "--remote-state-dir" => {
                index += 1;
                remote_state_dir = raw_args.get(index).map(PathBuf::from);
            }
            "--materialization-id" => {
                index += 1;
                materialization_id = raw_args.get(index).cloned();
            }
            "--inherit-enrollments" => enrollment_policy = MaterializedEnrollmentPolicy::Inherit,
            other => bail!("unknown argument {other:?}"),
        }
        index += 1;
    }
    Ok(Args {
        workspace_state_root: workspace_state_root
            .ok_or_else(|| anyhow::anyhow!("--workspace-state-root is required"))?,
        remote_state_dir: remote_state_dir
            .ok_or_else(|| anyhow::anyhow!("--remote-state-dir is required"))?,
        materialization_id: materialization_id
            .ok_or_else(|| anyhow::anyhow!("--materialization-id is required"))?,
        enrollment_policy,
    })
}

fn validate_materialization_id(value: &str) -> anyhow::Result<()> {
    if value.is_empty()
        || value.len() > 256
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        bail!("materialization id must be 1..=256 non-control bytes with no edge whitespace");
    }
    Ok(())
}

fn prepare_marker(path: &Path, args: &Args) -> anyhow::Result<MaterializationMarker> {
    let identity = StaticIdentity::generate().context("generate materialized daemon identity")?;
    let machine_id = MachinePublicId::random().context("generate materialized machine id")?;
    let marker = MaterializationMarker {
        version: 1,
        phase: "pending".into(),
        materialization_id: args.materialization_id.clone(),
        machine_id: machine_id.as_str().to_owned(),
        daemon_fingerprint: identity.fingerprint(),
        enrollment_policy: policy_name(args.enrollment_policy).into(),
        daemon_private_key: Some(
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(identity.private_key()),
        ),
    };
    atomic_marker(path, &marker)?;
    Ok(marker)
}

fn read_marker(path: &Path) -> anyhow::Result<Option<MaterializationMarker>> {
    match fs::read(path) {
        Ok(data) => Ok(Some(
            serde_json::from_slice(&data)
                .with_context(|| format!("parse materialization marker {}", path.display()))?,
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("read materialization marker {}", path.display()))
        }
    }
}

fn atomic_marker(path: &Path, marker: &MaterializationMarker) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("materialization marker has no parent"))?;
    let temporary = parent.join(format!(
        ".{MARKER_FILE}.tmp-{}-{:016x}",
        std::process::id(),
        random_u64()?
    ));
    let data = serde_json::to_vec_pretty(marker)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
    let mut file = options
        .open(&temporary)
        .with_context(|| format!("create staged materialization marker {}", temporary.display()))?;
    let result = (|| {
        file.write_all(&data)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        cmux_tui_core::platform::restrict_file(path)?;
        cmux_tui_core::platform::sync_directory(parent)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn random_u64() -> anyhow::Result<u64> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("generate materialization staging suffix: {error}"))?;
    Ok(u64::from_le_bytes(bytes))
}

fn decode_private_key(value: &str) -> anyhow::Result<[u8; 32]> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .context("decode pending daemon private key")?;
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("pending daemon private key has the wrong length"))
}

fn policy_name(policy: MaterializedEnrollmentPolicy) -> &'static str {
    match policy {
        MaterializedEnrollmentPolicy::Fresh => "fresh",
        MaterializedEnrollmentPolicy::Inherit => "inherit",
    }
}

fn parse_policy(value: &str) -> anyhow::Result<MaterializedEnrollmentPolicy> {
    match value {
        "fresh" => Ok(MaterializedEnrollmentPolicy::Fresh),
        "inherit" => Ok(MaterializedEnrollmentPolicy::Inherit),
        other => bail!("unsupported materialization enrollment policy {other:?}"),
    }
}

fn print_receipt(changed: bool, marker: &MaterializationMarker) {
    println!(
        "{}",
        serde_json::json!({
            "changed": changed,
            "materialization_id": marker.materialization_id,
            "machine_id": marker.machine_id,
            "daemon_fingerprint": marker.daemon_fingerprint,
            "enrollment_policy": marker.enrollment_policy,
        })
    );
}
