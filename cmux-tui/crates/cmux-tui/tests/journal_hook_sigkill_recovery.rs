#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

struct Harness {
    daemon: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
    session: String,
}

impl Harness {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-hook-sigkill-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut harness = Self {
            daemon: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            session: "hook-sigkill-regression".into(),
            dir,
        };
        harness.restart();
        harness
    }

    fn restart(&mut self) {
        assert!(self.daemon.is_none());
        let child = Command::new(bin())
            .args(["--headless", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.daemon = Some(child);
        wait_for_socket(&self.socket);
    }

    fn sigkill(&mut self) {
        let mut daemon = self.daemon.take().unwrap();
        let pid = daemon.id() as libc::pid_t;
        // SAFETY: the harness owns this dedicated daemon process.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
        daemon.wait().unwrap();
        let _ = fs::remove_file(&self.socket);
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        if let Some(mut daemon) = self.daemon.take() {
            let _ = daemon.kill();
            let _ = daemon.wait();
        }
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[derive(Debug, Clone)]
struct HookStart {
    correlation: String,
    attempt: u32,
    pid: libc::pid_t,
}

#[test]
fn mux_sigkill_loses_hook_timeout_and_parallel_owner() {
    let mut harness = Harness::start("owner-loss");
    let log = harness.dir.join("hook-starts.log");
    let script = harness.dir.join("hook.py");
    fs::write(
        &script,
        r#"import os, sys, time
path = sys.argv[1]
with open(path, 'a', buffering=1) as f:
    f.write(f"{os.environ['CMUX_JOURNAL_CORRELATION_ID']} {os.environ['CMUX_JOURNAL_ATTEMPT']} {os.getpid()}\n")
    f.flush()
    os.fsync(f.fileno())
while True:
    time.sleep(1)
"#,
    )
    .unwrap();

    let manifest = serde_json::json!({
        "hook_id":"sigkill_owner_probe",
        "manifest_version":1,
        "filter":{"kinds":["workspace.create"]},
        "exec":{
            "argv":["/usr/bin/python3", script, log],
            "timeout_ms":1000,
            "max_parallel":1
        },
        "delivery":{
            "start":"tail",
            "retry":{"max_attempts":3,"backoff_ms":10}
        },
        "permissions":["journal.read"]
    });
    let installed = cli(
        &harness.socket,
        &[
            "session",
            "current",
            "journal",
            "hook",
            "put",
            "--idempotency-key",
            "sigkill-owner-hook-v1",
            "--manifest-json",
            &manifest.to_string(),
        ],
    );
    assert_success(&installed);

    let created = resource_request(
        &harness.socket,
        "sigkill-owner-trigger",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"hook sigkill trigger",
            "initial_content":"empty"
        }),
        Some("sigkill-owner-trigger"),
    );
    assert!(created["value"]["workspace_id"].as_str().is_some(), "{created}");

    let first = wait_for_starts(&log, 1).remove(0);
    assert_eq!(first.attempt, 1, "unexpected first hook start: {first:?}");
    assert!(process_alive(first.pid));

    harness.sigkill();
    thread::sleep(Duration::from_millis(2_250));
    assert!(
        process_alive(first.pid),
        "hook attempt 1 died after mux SIGKILL; configured timeout unexpectedly survived owner death"
    );

    harness.restart();
    let starts = wait_for_starts(&log, 2);
    let second = starts[1].clone();
    assert_eq!(second.attempt, 2, "replacement did not retry the executing delivery: {starts:?}");
    assert_eq!(second.correlation, first.correlation, "retry changed durable delivery identity");
    assert_ne!(second.pid, first.pid, "replacement reused the original hook process");
    assert!(process_alive(first.pid), "attempt 1 ended before replacement attempt 2 started");
    assert!(process_alive(second.pid), "attempt 2 was not live when overlap was observed");

    // The manifest says max_parallel=1, yet both attempts for the same hook are
    // live concurrently because replacement accounting cannot see attempt 1.
    // Cleanup is external because the assertion deliberately reproduces the
    // missing owner handoff.
    kill_process(first.pid);
    kill_process(second.pid);
}

fn cli(socket: &Path, args: &[&str]) -> Output {
    Command::new(bin())
        .arg("--json")
        .arg("--socket")
        .arg(socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "CLI failed: {:?}\nstdout={}\nstderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn resource_request(
    path: &Path,
    id: &str,
    operation: &str,
    params: serde_json::Value,
    idempotency_key: Option<&str>,
) -> serde_json::Value {
    let mut request = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params
    });
    if let Some(key) = idempotency_key {
        request["idempotency_key"] = serde_json::json!(key);
    }
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    writer.flush().unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "resource request failed: {response}");
    response["result"].clone()
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if path.exists() && transport::connect(path).is_ok() {
            return;
        }
        assert!(Instant::now() < deadline, "daemon socket did not become ready: {}", path.display());
        thread::sleep(Duration::from_millis(20));
    }
}

fn wait_for_starts(path: &Path, count: usize) -> Vec<HookStart> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(text) = fs::read_to_string(path) {
            let starts = text
                .lines()
                .filter_map(|line| {
                    let mut parts = line.split_whitespace();
                    Some(HookStart {
                        correlation: parts.next()?.to_string(),
                        attempt: parts.next()?.parse().ok()?,
                        pid: parts.next()?.parse().ok()?,
                    })
                })
                .collect::<Vec<_>>();
            if starts.len() >= count {
                return starts;
            }
        }
        assert!(Instant::now() < deadline, "hook did not record {count} starts: {}", path.display());
        thread::sleep(Duration::from_millis(10));
    }
}

fn process_alive(pid: libc::pid_t) -> bool {
    // SAFETY: signal zero only probes process existence.
    (unsafe { libc::kill(pid, 0) }) == 0
}

fn kill_process(pid: libc::pid_t) {
    // SAFETY: PIDs were written by the dedicated hook processes in this test.
    let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
