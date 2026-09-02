from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise AssertionError(f"{label}: expected one match, saw {count}")
    return text.replace(old, new, 1)


# Measurement-only counters are injected into the candidate source at CI runtime.
source_path = Path("cmux-tui/crates/chatmux-relay/src/journal_forwarder.rs")
text = source_path.read_text()

static_anchor = "#[cfg(unix)]\nstatic NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);\n"
text = replace_once(
    text,
    static_anchor,
    static_anchor
    + """
#[cfg(unix)]
static FIELDWORK_PENDING_RECORDS: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_PENDING_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_INFLIGHT_RECORDS: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_INFLIGHT_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_PEAK_OWNED_RECORDS: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_PEAK_OWNED_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static FIELDWORK_RETRY_ATTEMPTS: AtomicU64 = AtomicU64::new(0);
""",
    "source metric statics",
)

body_anchor = """fn batch_body_bytes(sessions: &[SessionBatch]) -> usize {
    serde_json::to_vec(&json!({ "sessions": sessions })).map_or(usize::MAX, |body| body.len())
}
"""
text = replace_once(
    text,
    body_anchor,
    body_anchor
    + """
#[cfg(unix)]
#[derive(Clone, Copy, Debug)]
pub struct JournalFieldworkMetrics {
    pub pending_records: u64,
    pub pending_bytes: u64,
    pub inflight_records: u64,
    pub inflight_bytes: u64,
    pub peak_owned_records: u64,
    pub peak_owned_bytes: u64,
    pub retry_attempts: u64,
}

#[cfg(unix)]
pub fn fieldwork_journal_metrics() -> JournalFieldworkMetrics {
    JournalFieldworkMetrics {
        pending_records: FIELDWORK_PENDING_RECORDS.load(Ordering::Relaxed),
        pending_bytes: FIELDWORK_PENDING_BYTES.load(Ordering::Relaxed),
        inflight_records: FIELDWORK_INFLIGHT_RECORDS.load(Ordering::Relaxed),
        inflight_bytes: FIELDWORK_INFLIGHT_BYTES.load(Ordering::Relaxed),
        peak_owned_records: FIELDWORK_PEAK_OWNED_RECORDS.load(Ordering::Relaxed),
        peak_owned_bytes: FIELDWORK_PEAK_OWNED_BYTES.load(Ordering::Relaxed),
        retry_attempts: FIELDWORK_RETRY_ATTEMPTS.load(Ordering::Relaxed),
    }
}

#[cfg(unix)]
fn fieldwork_update_peak(target: &AtomicU64, candidate: u64) {
    let mut current = target.load(Ordering::Relaxed);
    while candidate > current {
        match target.compare_exchange_weak(current, candidate, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => break,
            Err(actual) => current = actual,
        }
    }
}

#[cfg(unix)]
fn fieldwork_refresh_owned_peaks() {
    let records = FIELDWORK_PENDING_RECORDS
        .load(Ordering::Relaxed)
        .saturating_add(FIELDWORK_INFLIGHT_RECORDS.load(Ordering::Relaxed));
    let bytes = FIELDWORK_PENDING_BYTES
        .load(Ordering::Relaxed)
        .saturating_add(FIELDWORK_INFLIGHT_BYTES.load(Ordering::Relaxed));
    fieldwork_update_peak(&FIELDWORK_PEAK_OWNED_RECORDS, records);
    fieldwork_update_peak(&FIELDWORK_PEAK_OWNED_BYTES, bytes);
}

#[cfg(unix)]
fn fieldwork_set_pending(records: usize, bytes: usize) {
    FIELDWORK_PENDING_RECORDS.store(records as u64, Ordering::Relaxed);
    FIELDWORK_PENDING_BYTES.store(bytes as u64, Ordering::Relaxed);
    fieldwork_refresh_owned_peaks();
}

#[cfg(unix)]
fn fieldwork_set_inflight(sessions: &[SessionBatch]) {
    let records = sessions.iter().map(|session| session.records.len()).sum::<usize>();
    FIELDWORK_INFLIGHT_RECORDS.store(records as u64, Ordering::Relaxed);
    FIELDWORK_INFLIGHT_BYTES.store(batch_body_bytes(sessions) as u64, Ordering::Relaxed);
    fieldwork_refresh_owned_peaks();
}

#[cfg(unix)]
fn fieldwork_clear_inflight() {
    FIELDWORK_INFLIGHT_RECORDS.store(0, Ordering::Relaxed);
    FIELDWORK_INFLIGHT_BYTES.store(0, Ordering::Relaxed);
}

#[cfg(unix)]
fn fieldwork_retry_attempt() {
    FIELDWORK_RETRY_ATTEMPTS.fetch_add(1, Ordering::Relaxed);
}
""",
    "source metric helpers",
)

text, replacements = re.subn(
    r"(?P<indent>[ \t]*)pool\.pending_records = 0;\n(?P=indent)pool\.pending_bytes = 0;",
    lambda match: (
        f"{match.group('indent')}pool.pending_records = 0;\n"
        f"{match.group('indent')}pool.pending_bytes = 0;\n"
        f"{match.group('indent')}fieldwork_set_pending(0, 0);"
    ),
    text,
)
if replacements < 3:
    raise AssertionError(f"pending reset instrumentation: expected >=3, saw {replacements}")

pending_anchor = """    pool.pending_records = pool.pending_records.saturating_add(1);
    pool.pending_bytes = pool.pending_bytes.saturating_add(record_bytes);
"""
text = replace_once(
    text,
    pending_anchor,
    pending_anchor + "    fieldwork_set_pending(pool.pending_records, pool.pending_bytes);\n",
    "pending occupancy update",
)

retry_loop_anchor = """        let mut attempt = 0_u32;
        loop {
"""
text = replace_once(
    text,
    retry_loop_anchor,
    """        let mut attempt = 0_u32;
        loop {
            fieldwork_set_inflight(&batches);
""",
    "inflight batch update",
)

retry_count = text.count("attempt = attempt.saturating_add(1);")
if retry_count != 2:
    raise AssertionError(f"retry instrumentation: expected 2 retry sites, saw {retry_count}")
text = text.replace(
    "attempt = attempt.saturating_add(1);",
    "attempt = attempt.saturating_add(1);\n                fieldwork_retry_attempt();",
)

post_anchor = "        let delivered = post_with_retry(shared, batches).await;\n"
text = replace_once(
    text,
    post_anchor,
    post_anchor + "        fieldwork_clear_inflight();\n",
    "clear inflight after delivery",
)

shutdown_anchor = "    let _ = flusher.await;\n}\n"
text = replace_once(
    text,
    shutdown_anchor,
    "    let _ = flusher.await;\n    fieldwork_set_pending(0, 0);\n    fieldwork_clear_inflight();\n}\n",
    "shutdown metric cleanup",
)
source_path.write_text(text)


# Turn the base fieldwork harness into an outage/recovery harness in-place.
# The source file remains experiment-only and is copied into the checkout by CI.
harness_path = Path("cmux-tui/crates/chatmux-relay/examples/fieldwork_journal_backlog.rs")
harness = harness_path.read_text()

harness = replace_once(
    harness,
    "use std::sync::atomic::{AtomicUsize, Ordering};\n",
    "use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};\n",
    "atomic bool import",
)
harness = replace_once(
    harness,
    "use std::time::{Duration, SystemTime, UNIX_EPOCH};\n",
    "use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};\n",
    "instant import",
)

harness = replace_once(
    harness,
    """enum HttpMode {
    Ack,
    Stall,
}
""",
    """enum HttpMode {
    Ack,
    Stall,
    Recover,
    RetryRecover,
}
""",
    "http modes",
)
harness = replace_once(
    harness,
    "[--mode ack|stall] [--settle-millis N] [--load-millis N]",
    "[--mode ack|stall|recover|retry-recover] [--settle-millis N] [--load-millis N]",
    "usage modes",
)
harness = replace_once(
    harness,
    """                    "ack" => HttpMode::Ack,
                    "stall" => HttpMode::Stall,
                    _ => usage(),
""",
    """                    "ack" => HttpMode::Ack,
                    "stall" => HttpMode::Stall,
                    "recover" => HttpMode::Recover,
                    "retry-recover" => HttpMode::RetryRecover,
                    _ => usage(),
""",
    "mode parser",
)
harness = replace_once(
    harness,
    """    if options.sessions == 0 || options.records_per_session == 0 || options.payload_bytes == 0 {
        usage();
    }
    options
}
""",
    """    if options.sessions == 0 || options.records_per_session == 0 || options.payload_bytes == 0 {
        usage();
    }
    if matches!(options.mode, HttpMode::Recover | HttpMode::RetryRecover)
        && options.load_millis.is_none()
    {
        usage();
    }
    options
}
""",
    "recover load validation",
)

harness = replace_once(
    harness,
    """    generated: Arc<AtomicUsize>,
    completed: Arc<AtomicUsize>,
    cancellation: CancellationToken,
""",
    """    generated: Arc<AtomicUsize>,
    completed: Arc<AtomicUsize>,
    producer_cancellation: CancellationToken,
    cancellation: CancellationToken,
""",
    "producer cancellation argument",
)
harness = replace_once(
    harness,
    """        let result = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            result = write_json_line(&mut write_half, &envelope) => result,
        };
""",
    """        let result = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            _ = producer_cancellation.cancelled() => break,
            result = write_json_line(&mut write_half, &envelope) => result,
        };
""",
    "producer cancellation select",
)

harness = replace_once(
    harness,
    "async fn read_http_request(stream: &mut TcpStream) -> io::Result<()> {\n",
    "async fn read_http_request(stream: &mut TcpStream) -> io::Result<Vec<u8>> {\n",
    "http request return type",
)
harness = replace_once(
    harness,
    """    Ok(())
}

async fn handle_http(
""",
    """    Ok(bytes[header_end..required].to_vec())
}

fn http_record_count(body: &[u8]) -> usize {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| value.get("sessions").and_then(Value::as_array).cloned())
        .map(|sessions| {
            sessions
                .iter()
                .map(|session| {
                    session
                        .get("records")
                        .and_then(Value::as_array)
                        .map_or(0, Vec::len)
                })
                .sum()
        })
        .unwrap_or(0)
}

async fn write_http_ack(stream: &mut TcpStream) -> io::Result<()> {
    let body = br#"{"cursors":{}}"#;
    let response = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(response.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.shutdown().await
}

async fn handle_http(
""",
    "http body helpers",
)

old_handle = """async fn handle_http(
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
"""
new_handle = """async fn handle_http(
    mut stream: TcpStream,
    mode: HttpMode,
    requests: Arc<AtomicUsize>,
    delivered_records: Arc<AtomicUsize>,
    recovery_wake: Arc<tokio::sync::Notify>,
    recovered: Arc<AtomicBool>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    let body = read_http_request(&mut stream).await?;
    let record_count = http_record_count(&body);
    requests.fetch_add(1, Ordering::SeqCst);
    match mode {
        HttpMode::Stall => {
            cancellation.cancelled().await;
        }
        HttpMode::Ack => {
            write_http_ack(&mut stream).await?;
            delivered_records.fetch_add(record_count, Ordering::SeqCst);
        }
        HttpMode::Recover => {
            if !recovered.load(Ordering::SeqCst) {
                let mut wake = Box::pin(recovery_wake.notified());
                wake.as_mut().enable();
                if !recovered.load(Ordering::SeqCst) {
                    tokio::select! {
                        _ = cancellation.cancelled() => return Ok(()),
                        _ = &mut wake => {}
                    }
                }
            }
            write_http_ack(&mut stream).await?;
            delivered_records.fetch_add(record_count, Ordering::SeqCst);
        }
        HttpMode::RetryRecover => {
            if recovered.load(Ordering::SeqCst) {
                write_http_ack(&mut stream).await?;
                delivered_records.fetch_add(record_count, Ordering::SeqCst);
            } else {
                let body = br#"{"error":"fieldwork retry"}"#;
                let response = format!(
                    "HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await?;
                stream.write_all(body).await?;
                stream.shutdown().await?;
            }
        }
    }
    Ok(())
}
"""
harness = replace_once(harness, old_handle, new_handle, "http handler")

old_server = """async fn run_http_server(
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
"""
new_server = """async fn run_http_server(
    listener: TcpListener,
    mode: HttpMode,
    requests: Arc<AtomicUsize>,
    delivered_records: Arc<AtomicUsize>,
    recovery_wake: Arc<tokio::sync::Notify>,
    recovered: Arc<AtomicBool>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    loop {
        let accepted = tokio::select! {
            _ = cancellation.cancelled() => return Ok(()),
            accepted = listener.accept() => accepted?,
        };
        let (stream, _) = accepted;
        let requests = requests.clone();
        let delivered_records = delivered_records.clone();
        let recovery_wake = recovery_wake.clone();
        let recovered = recovered.clone();
        let cancellation = cancellation.clone();
        tokio::spawn(async move {
            let _ = handle_http(
                stream,
                mode,
                requests,
                delivered_records,
                recovery_wake,
                recovered,
                cancellation,
            )
            .await;
        });
    }
}
"""
harness = replace_once(harness, old_server, new_server, "http server")

fd_anchor = """fn current_fd_count() -> Option<usize> {
    for path in ["/proc/self/fd", "/dev/fd"] {
        if let Ok(entries) = fs::read_dir(path) {
            return Some(entries.count());
        }
    }
    None
}
"""
harness = replace_once(
    harness,
    fd_anchor,
    fd_anchor
    + """
fn current_thread_count() -> Option<usize> {
    let output = Command::new("ps")
        .args(["-M", "-p", &std::process::id().to_string(), "-o", "pid="])
        .output()
        .ok()?;
    output.status.success().then(|| {
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter(|line| !line.trim().is_empty())
            .count()
    })
}

fn current_descendant_count() -> Option<usize> {
    let output = Command::new("pgrep")
        .args(["-P", &std::process::id().to_string()])
        .output()
        .ok()?;
    if output.status.success() {
        Some(
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter(|line| !line.trim().is_empty())
                .count(),
        )
    } else {
        Some(0)
    }
}

fn current_socket_count() -> Option<usize> {
    let output = Command::new("lsof")
        .args(["-nP", "-a", "-p", &std::process::id().to_string(), "-F", "t"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter(|line| matches!(*line, "tIPv4" | "tIPv6" | "tunix"))
            .count(),
    )
}
""",
    "resource helper metrics",
)

harness = replace_once(
    harness,
    """    let completed = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(AtomicUsize::new(0));
    let mut tasks: Vec<JoinHandle<()>> = Vec::new();
""",
    """    let completed = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(AtomicUsize::new(0));
    let delivered_records = Arc::new(AtomicUsize::new(0));
    let producer_cancellation = CancellationToken::new();
    let recovery_wake = Arc::new(tokio::sync::Notify::new());
    let recovered = Arc::new(AtomicBool::new(false));
    let mut tasks: Vec<JoinHandle<()>> = Vec::new();
""",
    "main recovery state",
)

harness = replace_once(
    harness,
    """        let generated = generated.clone();
        let completed = completed.clone();
        let cancellation = cancellation.clone();
""",
    """        let generated = generated.clone();
        let completed = completed.clone();
        let producer_cancellation = producer_cancellation.clone();
        let cancellation = cancellation.clone();
""",
    "clone producer cancellation",
)
harness = replace_once(
    harness,
    """                generated,
                completed,
                cancellation,
""",
    """                generated,
                completed,
                producer_cancellation,
                cancellation,
""",
    "pass producer cancellation",
)

harness = replace_once(
    harness,
    """    {
        let requests = requests.clone();
        let cancellation = cancellation.clone();
        let mode = options.mode;
        tasks.push(tokio::spawn(async move {
            if let Err(error) = run_http_server(http_listener, mode, requests, cancellation).await {
                eprintln!("fake HTTP server failed: {error}");
            }
        }));
    }
""",
    """    {
        let requests = requests.clone();
        let delivered_records = delivered_records.clone();
        let recovery_wake = recovery_wake.clone();
        let recovered = recovered.clone();
        let cancellation = cancellation.clone();
        let mode = options.mode;
        tasks.push(tokio::spawn(async move {
            if let Err(error) = run_http_server(
                http_listener,
                mode,
                requests,
                delivered_records,
                recovery_wake,
                recovered,
                cancellation,
            )
            .await
            {
                eprintln!("fake HTTP server failed: {error}");
            }
        }));
    }
""",
    "spawn http server",
)

baseline_anchor = """    let baseline_rss_kib = current_rss_kib();
    let baseline_fds = current_fd_count();
"""
harness = replace_once(
    harness,
    baseline_anchor,
    baseline_anchor
    + """    let baseline_threads = current_thread_count();
    let baseline_descendants = current_descendant_count();
    let baseline_sockets = current_socket_count();
""",
    "baseline resource metrics",
)

harness = replace_once(
    harness,
    """    if options.mode == HttpMode::Stall {
        wait_for_counter(&requests, 1, Duration::from_secs(10), "first HTTP POST").await?;
    }

    if let Some(load_millis) = options.load_millis {
        tokio::time::sleep(Duration::from_millis(load_millis)).await;
    } else {
""",
    """    if matches!(
        options.mode,
        HttpMode::Stall | HttpMode::Recover | HttpMode::RetryRecover
    ) {
        wait_for_counter(&requests, 1, Duration::from_secs(10), "first HTTP POST").await?;
    }

    if let Some(load_millis) = options.load_millis {
        tokio::time::sleep(Duration::from_millis(load_millis)).await;
        if matches!(options.mode, HttpMode::Recover | HttpMode::RetryRecover) {
            producer_cancellation.cancel();
            wait_for_counter(
                &completed,
                expected_active,
                Duration::from_secs(5),
                "stopped producers",
            )
            .await?;
        }
    } else {
""",
    "load/recovery producer control",
)

loaded_anchor = """    let loaded_generated_records = generated.load(Ordering::SeqCst);
    let loaded_completed_producers = completed.load(Ordering::SeqCst);

    cancellation.cancel();
"""
harness = replace_once(
    harness,
    loaded_anchor,
    """    let loaded_generated_records = generated.load(Ordering::SeqCst);
    let loaded_completed_producers = completed.load(Ordering::SeqCst);
    let loaded_delivered_records = delivered_records.load(Ordering::SeqCst);
    let loaded_forwarder_metrics = journal_forwarder::fieldwork_journal_metrics();
    let loaded_threads = current_thread_count();
    let loaded_descendants = current_descendant_count();
    let loaded_sockets = current_socket_count();

    let mut recovery_settle_millis = None;
    let mut recovered_rss_kib = None;
    let mut recovered_fds = None;
    let mut recovered_http_requests = None;
    let mut recovered_delivered_records = None;
    let mut recovered_forwarder_metrics = None;
    let mut recovered_threads = None;
    let mut recovered_descendants = None;
    let mut recovered_sockets = None;
    if matches!(options.mode, HttpMode::Recover | HttpMode::RetryRecover) {
        let target_records = loaded_generated_records;
        let started = Instant::now();
        recovered.store(true, Ordering::SeqCst);
        recovery_wake.notify_waiters();
        wait_for_counter(
            &delivered_records,
            target_records,
            Duration::from_secs(30),
            "records delivered after HTTP recovery",
        )
        .await?;
        recovery_settle_millis = Some(started.elapsed().as_millis() as u64);
        tokio::time::sleep(Duration::from_millis(options.settle_millis)).await;
        recovered_rss_kib = current_rss_kib();
        recovered_fds = current_fd_count();
        recovered_http_requests = Some(requests.load(Ordering::SeqCst));
        recovered_delivered_records = Some(delivered_records.load(Ordering::SeqCst));
        recovered_forwarder_metrics = Some(journal_forwarder::fieldwork_journal_metrics());
        recovered_threads = current_thread_count();
        recovered_descendants = current_descendant_count();
        recovered_sockets = current_socket_count();
    }

    cancellation.cancel();
""",
    "loaded and recovered metrics",
)

cleanup_anchor = """    let cleanup_rss_kib = current_rss_kib();
    let cleanup_fds = current_fd_count();

    let output = json!({
"""
harness = replace_once(
    harness,
    cleanup_anchor,
    """    let cleanup_rss_kib = current_rss_kib();
    let cleanup_fds = current_fd_count();
    let cleanup_forwarder_metrics = journal_forwarder::fieldwork_journal_metrics();
    let cleanup_threads = current_thread_count();
    let cleanup_descendants = current_descendant_count();
    let cleanup_sockets = current_socket_count();

    let output = json!({
""",
    "cleanup metrics",
)

old_output = """        "mode": match options.mode { HttpMode::Ack => "ack", HttpMode::Stall => "stall" },
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
"""
new_output = """        "mode": match options.mode {
            HttpMode::Ack => "ack",
            HttpMode::Stall => "stall",
            HttpMode::Recover => "recover",
            HttpMode::RetryRecover => "retry-recover",
        },
        "requested_sessions": options.sessions,
        "source_discovered_session_cap": discovered_cap,
        "accepted_sessions": accepted.load(Ordering::SeqCst),
        "records_per_session_limit": options.records_per_session,
        "payload_bytes": options.payload_bytes,
        "load_millis": options.load_millis,
        "generated_records_at_measurement": loaded_generated_records,
        "completed_producers_at_measurement": loaded_completed_producers,
        "delivered_records_at_measurement": loaded_delivered_records,
        "recovery_settle_millis": recovery_settle_millis,
        "recovered_delivered_records": recovered_delivered_records,
        "recovered_http_requests": recovered_http_requests,
        "http_requests": http_requests,
        "loaded_pending_records": loaded_forwarder_metrics.pending_records,
        "loaded_pending_bytes": loaded_forwarder_metrics.pending_bytes,
        "loaded_inflight_records": loaded_forwarder_metrics.inflight_records,
        "loaded_inflight_bytes": loaded_forwarder_metrics.inflight_bytes,
        "peak_owned_records": loaded_forwarder_metrics.peak_owned_records,
        "peak_owned_bytes": loaded_forwarder_metrics.peak_owned_bytes,
        "retry_attempts_at_measurement": loaded_forwarder_metrics.retry_attempts,
        "recovered_pending_records": recovered_forwarder_metrics.map(|metrics| metrics.pending_records),
        "recovered_pending_bytes": recovered_forwarder_metrics.map(|metrics| metrics.pending_bytes),
        "recovered_inflight_records": recovered_forwarder_metrics.map(|metrics| metrics.inflight_records),
        "recovered_inflight_bytes": recovered_forwarder_metrics.map(|metrics| metrics.inflight_bytes),
        "retry_attempts_after_recovery": recovered_forwarder_metrics.map(|metrics| metrics.retry_attempts),
        "cleanup_pending_records": cleanup_forwarder_metrics.pending_records,
        "cleanup_pending_bytes": cleanup_forwarder_metrics.pending_bytes,
        "cleanup_inflight_records": cleanup_forwarder_metrics.inflight_records,
        "cleanup_inflight_bytes": cleanup_forwarder_metrics.inflight_bytes,
        "source_max_batch_records": batch_records,
        "source_max_batch_body_bytes": batch_body_bytes,
        "baseline_rss_kib": baseline_rss_kib,
        "loaded_rss_kib": loaded_rss_kib,
        "recovered_rss_kib": recovered_rss_kib,
        "cleanup_rss_kib": cleanup_rss_kib,
        "baseline_fds": baseline_fds,
        "loaded_fds": loaded_fds,
        "recovered_fds": recovered_fds,
        "cleanup_fds": cleanup_fds,
        "baseline_threads": baseline_threads,
        "loaded_threads": loaded_threads,
        "recovered_threads": recovered_threads,
        "cleanup_threads": cleanup_threads,
        "baseline_descendants": baseline_descendants,
        "loaded_descendants": loaded_descendants,
        "recovered_descendants": recovered_descendants,
        "cleanup_descendants": cleanup_descendants,
        "baseline_sockets": baseline_sockets,
        "loaded_sockets": loaded_sockets,
        "recovered_sockets": recovered_sockets,
        "cleanup_sockets": cleanup_sockets,
"""
harness = replace_once(harness, old_output, new_output, "json output")
harness_path.write_text(harness)
