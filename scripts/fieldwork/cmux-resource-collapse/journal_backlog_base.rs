use std::env;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chatmux_relay::config::{ManagedEvents, ManagedEventsMode};
use chatmux_relay::journal_forwarder;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HttpMode {
    Ack,
    Stall,
}

#[derive(Clone, Copy, Debug)]
struct Options {
    sessions: usize,
    records_per_session: usize,
    payload_bytes: usize,
    mode: HttpMode,
    settle_millis: u64,
    load_millis: Option<u64>,
}

fn usage() -> ! {
    eprintln!(
        "usage: fieldwork_journal_backlog [--sessions N] [--records-per-session N] [--payload-bytes N] [--mode ack|stall] [--settle-millis N] [--load-millis N]"
    );
    std::process::exit(2);
}

fn parse_options() -> Options {
    let mut options = Options {
        sessions: 1,
        records_per_session: 1000,
        payload_bytes: 2048,
        mode: HttpMode::Stall,
        settle_millis: 500,
        load_millis: None,
    };
    let mut args = env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--sessions" => {
                options.sessions = args.next().unwrap_or_else(|| usage()).parse().unwrap_or_else(|_| usage());
            }
            "--records-per-session" => {
                options.records_per_session = args.next().unwrap_or_else(|| usage()).parse().unwrap_or_else(|_| usage());
            }
            "--payload-bytes" => {
                options.payload_bytes = args.next().unwrap_or_else(|| usage()).parse().unwrap_or_else(|_| usage());
            }
            "--mode" => {
                options.mode = match args.next().unwrap_or_else(|| usage()).as_str() {
                    "ack" => HttpMode::Ack,
                    "stall" => HttpMode::Stall,
                    _ => usage(),
                };
            }
            "--settle-millis" => {
                options.settle_millis = args.next().unwrap_or_else(|| usage()).parse().unwrap_or_else(|_| usage());
            }
            "--load-millis" => {
                options.load_millis = Some(args.next().unwrap_or_else(|| usage()).parse().unwrap_or_else(|_| usage()));
            }
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
    // macOS Unix-domain sockets have a short SUN_LEN pathname ceiling. Use a
    // deliberately compact experiment root instead of the much longer
    // per-user path returned by temp_dir().
    let root = PathBuf::from("/tmp").join(format!("jfw-{}-{nonce:x}", std::process::id()));
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

async fn write_json_line(stream: &mut tokio::net::unix::OwnedWriteHalf, value: &Value) -> io::Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    stream.write_all(&line).await
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
    let mut request = String::new();
    tokio::select! {
        _ = cancellation.cancelled() => return Ok(()),
        read = reader.read_line(&mut request) => {
            if read? == 0 {
                return Ok(());
            }
        }
    }
    let generation = format!("fieldwork-generation-{session_index:04}");
    let hello = json!({
        "id": "chatmux-journal-subscribe",
        "result": {
            "protocol": "cmux.protocol/2",
            "session": format!("fieldwork-{session_index:04}"),
            "generation": generation,
        }
    });
    write_json_line(&mut write_half, &hello).await?;

    let payload = "x".repeat(payload_bytes);
    for sequence in 1..=records {
        let envelope = json!({
            "method": "session.stream",
            "params": {
                "type": "stream_item",
                "sequence": sequence.to_string(),
                "cursor": {
                    "generation": generation,
                    "revision": sequence.to_string(),
                },
                "payload": {
                    "session": session_index,
                    "sequence": sequence,
                    "blob": payload,
                }
            }
        });
        let result = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            result = write_json_line(&mut write_half, &envelope) => result,
        };
        if result.is_err() {
            return result;
        }
        generated.fetch_add(1, Ordering::SeqCst);
    }
    completed.fetch_add(1, Ordering::SeqCst);
    cancellation.cancelled().await;
    Ok(())
}

async fn read_http_request(stream: &mut TcpStream) -> io::Result<()> {
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 8192];
    let mut header_end = None;
    let mut content_length = 0_usize;
    loop {
        let read = stream.read(&mut buffer).await?;
        if read == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&buffer[..read]);
        if header_end.is_none() {
            if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                let end = position + 4;
                let header = String::from_utf8_lossy(&bytes[..end]);
                content_length = header
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().ok())
                            .flatten()
                    })
                    .unwrap_or(0);
                header_end = Some(end);
            }
        }
        if let Some(end) = header_end {
            if bytes.len() >= end.saturating_add(content_length) {
                return Ok(());
            }
        }
    }
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
            let body = br#"{\"cursors\":{}}"#;
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
