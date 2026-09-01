#![cfg(unix)]

use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chatmux_relay::config::ManagedEvents;
use chatmux_relay::journal_forwarder;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

const PROTOCOL: &str = "cmux.protocol/2";
const IDENTITY_ID: &str = "chatmux-journal-identity";
const SUBSCRIBE_ID: &str = "chatmux-journal-subscribe";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HttpMode {
    Ack,
    Stall,
}

#[derive(Debug)]
struct Options {
    sessions: usize,
    records_per_session: usize,
    payload_bytes: usize,
    mode: HttpMode,
    settle_millis: u64,
    load_millis: Option<u64>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            sessions: 1,
            records_per_session: 2_000,
            payload_bytes: 2_048,
            mode: HttpMode::Stall,
            settle_millis: 750,
            load_millis: None,
        }
    }
}

fn usage() -> ! {
    eprintln!(
        "usage: cargo run -p chatmux-relay --example fieldwork_journal_backlog -- \\\n         [--sessions N] [--records-per-session N] [--payload-bytes N] \\\n         [--mode ack|stall] [--settle-millis N] [--load-millis N]"
    );
    std::process::exit(2);
}

fn parse_options() -> Options {
    let mut options = Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| usage());
        match flag.as_str() {
            "--sessions" => options.sessions = value().parse().unwrap_or_else(|_| usage()),
            "--records-per-session" => {
                options.records_per_session = value().parse().unwrap_or_else(|_| usage())
            }
            "--payload-bytes" => {
                options.payload_bytes = value().parse().unwrap_or_else(|_| usage())
            }
            "--mode" => {
                options.mode = match value().as_str() {
                    "ack" => HttpMode::Ack,
                    "stall" => HttpMode::Stall,
                    _ => usage(),
                }
            }
            "--settle-millis" => {
                options.settle_millis = value().parse().unwrap_or_else(|_| usage())
            }
            "--load-millis" => {
                options.load_millis = Some(value().parse().unwrap_or_else(|_| usage()))
            }
            "-h" | "--help" => usage(),
            _ => usage(),
        }
    }
    if options.sessions == 0 || options.records_per_session == 0 || options.payload_bytes == 0 {
        usage();
    }
    options
}

fn source_usize_constant(name: &str) -> usize {
    let source = include_str!("../src/journal_forwarder.rs");
    let prefix = format!("const {name}: usize = ");
    let public_prefix = format!("pub const {name}: usize = ");
    let start = source
        .find(&public_prefix)
        .map(|index| index + public_prefix.len())
        .or_else(|| source.find(&prefix).map(|index| index + prefix.len()))
        .unwrap_or_else(|| panic!("missing source constant {name}"));
    let expression = source[start..]
        .split(';')
        .next()
        .expect("constant expression")
        .trim();
    if let Ok(value) = expression.parse() {
        return value;
    }
    expression
        .split('*')
        .map(|part| part.trim().parse::<usize>().expect("integer product term"))
        .product()
}

fn temporary_root() -> io::Result<PathBuf> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("cmux-fieldwork-journal-{}-{nonce}", std::process::id()));
    fs::create_dir_all(&root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
    Ok(root)
}

fn socket_directory(root: &Path) -> io::Result<PathBuf> {
    let directory = root.join(format!("cmux-tui-{}", unsafe { libc::getuid() }));
    fs::create_dir_all(&directory)?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    Ok(directory)
}

fn current_rss_kib() -> Option<u64> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()?.trim().parse().ok()
}

fn current_fd_count() -> Option<usize> {
    for path in ["/proc/self/fd", "/dev/fd"] {
        if let Ok(entries) = fs::read_dir(path) {
            return Some(entries.count());
        }
    }
    None
}

async fn write_json_line<W: AsyncWriteExt + Unpin>(writer: &mut W, value: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await
}

async fn read_json_line<R: AsyncBufReadExt + Unpin>(reader: &mut R) -> io::Result<Value> {
    let mut line = String::new();
    let read = reader.read_line(&mut line).await?;
    if read == 0 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "peer closed"));
    }
    serde_json::from_str(line.trim_end()).map_err(io::Error::other)
}

async fn run_fake_session(
    listener: UnixListener,
    session_index: usize,
    records: usize,
    payload_bytes: usize,
    accepted: Arc<AtomicUsize>,
    generated: Arc<AtomicUsize>,
    completed: Arc<AtomicUsize>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    let (stream, _) = tokio::select! {
        _ = cancellation.cancelled() => return Ok(()),
        accepted = listener.accept() => accepted?,
    };
    accepted.fetch_add(1, Ordering::SeqCst);
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    let identity = read_json_line(&mut reader).await?;
    if identity.get("id").and_then(Value::as_str) != Some(IDENTITY_ID) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "unexpected identity request"));
    }
    let name = format!("fieldwork-{session_index:04}");
    write_json_line(
        &mut write_half,
        &json!({
            "protocol": PROTOCOL,
            "type": "response",
            "id": IDENTITY_ID,
            "ok": true,
            "result": [{"name": name}],
        }),
    )
    .await?;

    let subscribe = read_json_line(&mut reader).await?;
    if subscribe.get("id").and_then(Value::as_str) != Some(SUBSCRIBE_ID) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "unexpected subscribe request"));
    }
    let stream_id = subscribe
        .pointer("/params/stream_id")
        .and_then(Value::as_str)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing stream_id"))?
        .to_owned();
    let generation = format!("generation-{session_index:04}");
    write_json_line(
        &mut write_half,
        &json!({
            "protocol": PROTOCOL,
            "type": "response",
            "id": SUBSCRIBE_ID,
            "ok": true,
            "result": {"cursor": {"generation": generation, "revision": "0"}},
        }),
    )
    .await?;

    let payload = "x".repeat(payload_bytes);
    for sequence in 1..=records {
        let envelope = json!({
            "protocol": PROTOCOL,
            "type": "stream_item",
            "stream_id": stream_id,
            "cursor": {
                "generation": generation,
                "revision": sequence.to_string(),
            },
            "sequence": sequence.to_string(),
            "kind": "agent.fieldwork",
            "payload": {"blob": payload},
        });
        let result = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            result = write_json_line(&mut write_half, &envelope) => result,
        };
        result?;
        generated.fetch_add(1, Ordering::Relaxed);
    }
    completed.fetch_add(1, Ordering::SeqCst);
    cancellation.cancelled().await;
    Ok(())
}

async fn read_http_request(stream: &mut TcpStream) -> io::Result<()> {
    const MAX_REQUEST: usize = 8 * 1024 * 1024;
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 16 * 1024];
    let (header_end, content_length) = loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "HTTP request closed"));
        }
        bytes.extend_from_slice(&chunk[..read]);
        if bytes.len() > MAX_REQUEST {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "HTTP request too large"));
        }
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let header_end = index + 4;
            let headers = std::str::from_utf8(&bytes[..header_end])
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "HTTP headers are not UTF-8"))?;
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            break (header_end, content_length);
        }
    };
    let required = header_end.saturating_add(content_length);
    while bytes.len() < required {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "HTTP body closed"));
        }
        bytes.extend_from_slice(&chunk[..read]);
        if bytes.len() > MAX_REQUEST {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "HTTP request too large"));
        }
    }
    Ok(())
}

async fn handle_http(
    mut stream: TcpStream,
    mode: HttpMode,
    requests: Arc<AtomicUsize>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    read_http_request(&mut stream).await?;
    requests.fetch_add(1, Ordering::SeqCst);
    match mode {
        HttpMode::Stall => {
            cancellation.cancelled().await;
        }
        HttpMode::Ack => {
            let body = br#"{"cursors":{}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(response.as_bytes()).await?;
            stream.write_all(body).await?;
            stream.shutdown().await?;
        }
    }
    Ok(())
}

async fn run_http_server(
    listener: TcpListener,
    mode: HttpMode,
    requests: Arc<AtomicUsize>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    loop {
        let accepted = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            accepted = listener.accept() => accepted?,
        };
        let (stream, _) = accepted;
        let requests = requests.clone();
        let cancellation = cancellation.clone();
        tokio::spawn(async move {
            let _ = handle_http(stream, mode, requests, cancellation).await;
        });
    }
}

async fn wait_for_counter(
    counter: &AtomicUsize,
    expected: usize,
    timeout: Duration,
    name: &str,
) -> io::Result<()> {
    tokio::time::timeout(timeout, async {
        while counter.load(Ordering::SeqCst) < expected {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .map_err(|_| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            format!("timed out waiting for {name}: wanted {expected}, saw {}", counter.load(Ordering::SeqCst)),
        )
    })
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let options = parse_options();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let discovered_cap = source_usize_constant("MAX_DISCOVERED_SESSIONS");
    let batch_records = source_usize_constant("MAX_BATCH_RECORDS");
    let batch_body_bytes = source_usize_constant("MAX_BATCH_BODY_BYTES");
    let expected_active = options.sessions.min(discovered_cap);

    let root = temporary_root()?;
    let previous_runtime = std::env::var_os("XDG_RUNTIME_DIR");
    unsafe { std::env::set_var("XDG_RUNTIME_DIR", &root) };
    let socket_dir = socket_directory(&root)?;

    let cancellation = CancellationToken::new();
    let accepted = Arc::new(AtomicUsize::new(0));
    let generated = Arc::new(AtomicUsize::new(0));
    let completed = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(AtomicUsize::new(0));
    let mut tasks: Vec<JoinHandle<()>> = Vec::new();

    for index in 0..options.sessions {
        let path = socket_dir.join(format!("fieldwork-{index:04}.sock"));
        let listener = UnixListener::bind(path)?;
        let accepted = accepted.clone();
        let generated = generated.clone();
        let completed = completed.clone();
        let cancellation = cancellation.clone();
        let records = options.records_per_session;
        let payload_bytes = options.payload_bytes;
        tasks.push(tokio::spawn(async move {
            if let Err(error) = run_fake_session(
                listener,
                index,
                records,
                payload_bytes,
                accepted,
                generated,
                completed,
                cancellation,
            )
            .await
            {
                eprintln!("fake journal session {index} failed: {error}");
            }
        }));
    }

    let http_listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let http_address = http_listener.local_addr()?;
    {
        let requests = requests.clone();
        let cancellation = cancellation.clone();
        let mode = options.mode;
        tasks.push(tokio::spawn(async move {
            if let Err(error) = run_http_server(http_listener, mode, requests, cancellation).await {
                eprintln!("fake HTTP server failed: {error}");
            }
        }));
    }

    let baseline_rss_kib = current_rss_kib();
    let baseline_fds = current_fd_count();
    let forwarder = journal_forwarder::start(
        ManagedEvents {
            url: format!("http://{http_address}/events"),
            token: "fieldwork-token".to_owned(),
        },
        cancellation.clone(),
    );

    wait_for_counter(&accepted, expected_active, Duration::from_secs(10), "accepted sessions").await?;

    if options.mode == HttpMode::Stall {
        wait_for_counter(&requests, 1, Duration::from_secs(10), "first HTTP POST").await?;
    }

    if let Some(load_millis) = options.load_millis {
        tokio::time::sleep(Duration::from_millis(load_millis)).await;
    } else {
        wait_for_counter(&completed, expected_active, Duration::from_secs(30), "completed producers").await?;
        let expected_records = expected_active.saturating_mul(options.records_per_session);
        wait_for_counter(&generated, expected_records, Duration::from_secs(2), "generated records").await?;
    }

    tokio::time::sleep(Duration::from_millis(options.settle_millis)).await;

    let loaded_rss_kib = current_rss_kib();
    let loaded_fds = current_fd_count();
    let http_requests = requests.load(Ordering::SeqCst);
    let loaded_generated_records = generated.load(Ordering::SeqCst);
    let loaded_completed_producers = completed.load(Ordering::SeqCst);

    cancellation.cancel();
    let _ = forwarder.await;
    for task in tasks {
        let _ = task.await;
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let cleanup_rss_kib = current_rss_kib();
    let cleanup_fds = current_fd_count();

    let output = json!({
        "mode": match options.mode { HttpMode::Ack => "ack", HttpMode::Stall => "stall" },
        "requested_sessions": options.sessions,
        "source_discovered_session_cap": discovered_cap,
        "accepted_sessions": accepted.load(Ordering::SeqCst),
        "records_per_session_limit": options.records_per_session,
        "payload_bytes": options.payload_bytes,
        "load_millis": options.load_millis,
        "generated_records_at_measurement": loaded_generated_records,
        "completed_producers_at_measurement": loaded_completed_producers,
        "http_requests": http_requests,
        "source_max_batch_records": batch_records,
        "source_max_batch_body_bytes": batch_body_bytes,
        "baseline_rss_kib": baseline_rss_kib,
        "loaded_rss_kib": loaded_rss_kib,
        "cleanup_rss_kib": cleanup_rss_kib,
        "baseline_fds": baseline_fds,
        "loaded_fds": loaded_fds,
        "cleanup_fds": cleanup_fds,
    });
    println!("{}", serde_json::to_string_pretty(&output)?);

    if let Some(previous) = previous_runtime {
        unsafe { std::env::set_var("XDG_RUNTIME_DIR", previous) };
    } else {
        unsafe { std::env::remove_var("XDG_RUNTIME_DIR") };
    }
    let _ = fs::remove_dir_all(root);
    Ok(())
}
