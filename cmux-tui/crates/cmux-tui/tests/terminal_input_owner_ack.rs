#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, adopt_terminal_host, load_terminal_host_records,
    remove_stale_terminal_host_record, terminal_host_record_liveness, terminal_host_root,
};

struct Harness {
    child: Option<Child>,
    dir: tempfile::TempDir,
    socket: PathBuf,
    state: PathBuf,
    session: String,
}

impl Harness {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("mux.sock");
        let state = dir.path().join("state");
        let session = "terminal-input-owner-ack".to_string();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--session", &session, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        wait_for_socket(&socket);
        Self { child: Some(child), dir, socket, state, session }
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, &self.session)
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }

        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        let endpoints =
            records.iter().map(|(_, record)| PathBuf::from(&record.endpoint)).collect::<Vec<_>>();
        for (path, record) in &records {
            if let Ok(mut host) = adopt_terminal_host(record.clone(), path.clone()) {
                let _ = host.terminate();
                host.disconnect();
            }
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while endpoints.iter().any(|endpoint| endpoint.exists()) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        for (path, record) in &records {
            if terminal_host_record_liveness(path, record).ok() != Some(TerminalHostLiveness::Dead)
            {
                // SAFETY: this integration test owns the dedicated terminal host.
                let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
                let deadline = Instant::now() + Duration::from_secs(2);
                while terminal_host_record_liveness(path, record).ok()
                    != Some(TerminalHostLiveness::Dead)
                    && Instant::now() < deadline
                {
                    thread::sleep(Duration::from_millis(20));
                }
            }
            let _ = remove_stale_terminal_host_record(path, record);
        }
        for endpoint in endpoints {
            let _ = fs::remove_file(endpoint);
        }
    }
}

struct StoppedHost(libc::pid_t);

impl StoppedHost {
    fn stop(pid: u32) -> Self {
        let pid = pid as libc::pid_t;
        // SAFETY: the test owns this dedicated terminal-host process.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGSTOP) }, 0);
        Self(pid)
    }
}

impl Drop for StoppedHost {
    fn drop(&mut self) {
        // SAFETY: best-effort release of the dedicated host before harness teardown.
        let _ = unsafe { libc::kill(self.0, libc::SIGCONT) };
    }
}

#[test]
fn receipted_terminal_input_waits_for_the_host_pty_write_boundary() {
    let harness = Harness::start();
    let workspace = resource_request(
        &harness.socket,
        "input-ack-workspace",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"input ack",
            "initial_content":"empty",
        }),
        Some("input-ack-workspace"),
    );
    let workspace_id = workspace["value"]["workspace_id"].as_str().unwrap();

    let ready = harness.dir.path().join("child-ready");
    let effect = harness.dir.path().join("child-effect");
    let script = format!(
        "stty -echo -icanon min 1 time 0; : > {}; dd bs=1 count=1 of={} 2>/dev/null; sleep 30",
        shell_quote(&ready),
        shell_quote(&effect),
    );
    let run = resource_request(
        &harness.socket,
        "input-ack-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace_id,
            "argv":["/bin/sh","-c",script],
        }),
        Some("input-ack-run"),
    );
    let terminal = run["value"]["terminal_id"].as_str().unwrap().to_string();
    wait_for_file(&ready);

    let records = load_terminal_host_records(&harness.host_root()).unwrap();
    assert_eq!(records.len(), 1, "expected one terminal host: {records:?}");
    let host_pid = records[0].1.host_pid;
    let stopped = StoppedHost::stop(host_pid);

    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (response_tx, response_rx) = mpsc::sync_channel(1);
    let socket = harness.socket.clone();
    let request_thread = thread::spawn(move || {
        entered_tx.send(()).unwrap();
        let response = request_response(
            &socket,
            serde_json::json!({
                "protocol":"cmux.protocol/2",
                "type":"request",
                "id":"input-ack-write",
                "operation":"terminal.input.write",
                "idempotency_key":"input-ack-write",
                "params":{
                    "machine":"current",
                    "session":"current",
                    "terminal":terminal,
                    "text":"X",
                },
            }),
        );
        response_tx.send(response).unwrap();
    });
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    match response_rx.recv_timeout(Duration::from_secs(1)) {
        Err(mpsc::RecvTimeoutError::Timeout) => {}
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            panic!("input request thread disconnected before the host resumed")
        }
        Ok(response) => panic!(
            "receipted input completed while the authoritative terminal host was stopped: {response}"
        ),
    }
    assert!(!effect.exists(), "PTY child received input while its owner was stopped");

    drop(stopped);
    let response = response_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(response["ok"], true, "confirmed input failed after host resume: {response}");
    request_thread.join().unwrap();

    wait_for_file(&effect);
    assert_eq!(fs::read(&effect).unwrap(), b"X");
}

fn resource_request(
    path: &Path,
    id: &str,
    operation: &str,
    params: serde_json::Value,
    idempotency_key: Option<&str>,
) -> serde_json::Value {
    let mut value = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        value["idempotency_key"] = serde_json::json!(idempotency_key);
    }
    let response = request_response(path, value);
    assert_eq!(response["protocol"], "cmux.protocol/2", "request failed: {response}");
    assert_eq!(response["type"], "response", "request failed: {response}");
    assert_eq!(response["id"], id, "request failed: {response}");
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["result"].clone()
}

fn request_response(path: &Path, request: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if path.exists() && transport::connect(path).is_ok() {
            return;
        }
        assert!(Instant::now() < deadline, "cmux-tui socket did not become ready: {}", path.display());
        thread::sleep(Duration::from_millis(20));
    }
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(Instant::now() < deadline, "file did not appear: {}", path.display());
        thread::sleep(Duration::from_millis(10));
    }
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
