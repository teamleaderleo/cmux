use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use anyhow::{Context, bail};
#[cfg(unix)]
use base64::Engine as _;
#[cfg(unix)]
use cmux_remote::crypto::StaticIdentity;
#[cfg(unix)]
use cmux_remote::materialization::{
    MaterializedEnrollmentPolicy, install_materialized_daemon_identity,
};
#[cfg(unix)]
use cmux_tui_core::materialization::install_materialized_machine_id;
#[cfg(unix)]
use cmux_tui_core::resource::MachinePublicId;
#[cfg(unix)]
use fs4::FileExt;
#[cfg(unix)]
use serde::{Deserialize, Serialize};

#[cfg(unix)]
const MARKER_FILE: &str = "cloud-materialization.json";
#[cfg(unix)]
const MARKER_LOCK_FILE: &str = "cloud-materialization.lock";

#[cfg(unix)]
#[derive(Debug)]
struct Args {
    workspace_state_root: PathBuf,
    remote_state_dir: PathBuf,
    materialization_id: String,
    enrollment_policy: MaterializedEnrollmentPolicy,
}

#[cfg(unix)]
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

#[cfg(unix)]
fn main() {
    if let Err(error) = run() {
        eprintln!("cmux-tui-materialize: {error:#}");
        std::process::exit(1);
    }
}

#[cfg(not(unix))]
fn main() {
    eprintln!("cmux-tui-materialize is currently supported only on Unix Cloud hosts");
    std::process::exit(2);
}

#[cfg(unix)]
fn run() -> anyhow::Result<()> {
    let args = parse_args()?;
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
    FileExt::try_lock(&lock).with_context(|| {
        format!("another materialization owns {}", lock_path.display())
    })?;

    let marker_path = args.workspace_state_root.join(MARKER_FILE);
    let marker = match read_marker(&marker_path)? {
        Some(marker)
            if marker.materialization_id == args.materialization_id && marker.phase == "committed" =>
        {
            println!(
                "{}",
                serde_json::json!({
                    "changed": false,
                    "materialization_id": marker.materialization_id,
                    "machine_id": marker.machine_id,
                    "daemon_fingerprint": marker.daemon_fingerprint,
                    "enrollment_policy": marker.enrollment_policy,
                })
            );
            let _ = FileExt::unlock(&lock);
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
        _ => prepare_marker(&marker_path, &args)?,
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

    install_materialized_daemon_identity(
        &args.remote_state_dir,
        &identity,
        enrollment_policy,
    )?;
    install_materialized_machine_id(&args.workspace_state_root, &machine_id)?;

    let committed = MaterializationMarker {
        version: marker.version,
        phase: "committed".into(),
        materialization_id: marker.materialization_id.clone(),
        machine_id: marker.machine_id.clone(),
        daemon_fingerprint: marker.daemon_fingerprint.clone(),
        enrollment_policy: marker.enrollment_policy.clone(),
        daemon_private_key: None,
    };
    atomic_marker(&marker_path, &committed)?;

    println!(
        "{}",
        serde_json::json!({
            "changed": true,
            "materialization_id": committed.materialization_id,
            "machine_id": committed.machine_id,
            "daemon_fingerprint": committed.daemon_fingerprint,
            "enrollment_policy": committed.enrollment_policy,
        })
    );
    let _ = FileExt::unlock(&lock);
    Ok(())
}

#[cfg(unix)]
fn parse_args() -> anyhow::Result<Args> {
    let mut workspace_state_root = None;
    let mut remote_state_dir = None;
    let mut materialization_id = None;
    let mut enrollment_policy = MaterializedEnrollmentPolicy::Fresh;
    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--workspace-state-root" => workspace_state_root = args.next().map(PathBuf::from),
            "--remote-state-dir" => remote_state_dir = args.next().map(PathBuf::from),
            "--materialization-id" => materialization_id = args.next(),
            "--inherit-enrollments" => enrollment_policy = MaterializedEnrollmentPolicy::Inherit,
            "--help" | "-h" => {
                println!(
                    "usage: cmux-tui-materialize --workspace-state-root <path> --remote-state-dir <path> --materialization-id <id> [--inherit-enrollments]"
                );
                std::process::exit(0);
            }
            other => bail!("unknown argument {other:?}"),
        }
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
fn read_marker(path: &Path) -> anyhow::Result<Option<MaterializationMarker>> {
    match fs::read(path) {
        Ok(data) => Ok(Some(
            serde_json::from_slice(&data)
                .with_context(|| format!("parse materialization marker {}", path.display()))?,
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("read materialization marker {}", path.display())),
    }
}

#[cfg(unix)]
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

#[cfg(unix)]
fn random_u64() -> anyhow::Result<u64> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("generate materialization staging suffix: {error}"))?;
    Ok(u64::from_le_bytes(bytes))
}

#[cfg(unix)]
fn decode_private_key(value: &str) -> anyhow::Result<[u8; 32]> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .context("decode pending daemon private key")?;
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("pending daemon private key has the wrong length"))
}

#[cfg(unix)]
fn policy_name(policy: MaterializedEnrollmentPolicy) -> &'static str {
    match policy {
        MaterializedEnrollmentPolicy::Fresh => "fresh",
        MaterializedEnrollmentPolicy::Inherit => "inherit",
    }
}

#[cfg(unix)]
fn parse_policy(value: &str) -> anyhow::Result<MaterializedEnrollmentPolicy> {
    match value {
        "fresh" => Ok(MaterializedEnrollmentPolicy::Fresh),
        "inherit" => Ok(MaterializedEnrollmentPolicy::Inherit),
        other => bail!("unsupported materialization enrollment policy {other:?}"),
    }
}
