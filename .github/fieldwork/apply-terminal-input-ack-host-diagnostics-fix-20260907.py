from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor changed (count={count})")
    return text.replace(old, new, 1)


diagnostics = Path("cmux-tui/crates/cmux-tui-core/src/diagnostics.rs")
text = diagnostics.read_text()
text = replace_once(
    text,
    '''/// Receipted terminal-input observations. These counters deliberately carry no
/// payload text or request-id labels: the goal is to separate submission,
/// owner-ACK wait, and bounded failure phases without retaining terminal data.
pub struct TerminalInputReceiptStats {
    submission_us: LogLinearHistogram,
    ack_wait_us: LogLinearHistogram,
    host_write_failures: AtomicU64,
    host_flush_failures: AtomicU64,
    host_ack_enqueue_rejections: AtomicU64,
    ack_timeouts: AtomicU64,
    last_host_write_error_kind: Mutex<Option<std::io::ErrorKind>>,
    last_host_flush_error_kind: Mutex<Option<std::io::ErrorKind>>,
    last_ack_timeout_outstanding_requests: AtomicU64,
    last_ack_timeout_outstanding_bytes: AtomicU64,
}

impl Default for TerminalInputReceiptStats {
    fn default() -> Self {
        Self {
            submission_us: LogLinearHistogram::new(),
            ack_wait_us: LogLinearHistogram::new(),
            host_write_failures: AtomicU64::new(0),
            host_flush_failures: AtomicU64::new(0),
            host_ack_enqueue_rejections: AtomicU64::new(0),
            ack_timeouts: AtomicU64::new(0),
            last_host_write_error_kind: Mutex::new(None),
            last_host_flush_error_kind: Mutex::new(None),
            last_ack_timeout_outstanding_requests: AtomicU64::new(0),
            last_ack_timeout_outstanding_bytes: AtomicU64::new(0),
        }
    }
}

impl TerminalInputReceiptStats {
    pub(crate) fn submission_finished(&self, duration: Duration) {
        self.submission_us.record_duration(duration);
    }

    pub(crate) fn ack_wait_finished(&self, duration: Duration) {
        self.ack_wait_us.record_duration(duration);
    }

    pub(crate) fn host_write_failed(&self, kind: std::io::ErrorKind) {
        self.host_write_failures.fetch_add(1, Ordering::Relaxed);
        *self.last_host_write_error_kind.lock().unwrap_or_else(|error| error.into_inner()) =
            Some(kind);
    }

    pub(crate) fn host_flush_failed(&self, kind: std::io::ErrorKind) {
        self.host_flush_failures.fetch_add(1, Ordering::Relaxed);
        *self.last_host_flush_error_kind.lock().unwrap_or_else(|error| error.into_inner()) =
            Some(kind);
    }

    pub(crate) fn host_ack_enqueue_rejected(&self) {
        self.host_ack_enqueue_rejections.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn ack_timed_out(&self, outstanding_requests: usize, outstanding_bytes: usize) {
        self.ack_timeouts.fetch_add(1, Ordering::Relaxed);
        self.last_ack_timeout_outstanding_requests
            .store(u64::try_from(outstanding_requests).unwrap_or(u64::MAX), Ordering::Relaxed);
        self.last_ack_timeout_outstanding_bytes
            .store(u64::try_from(outstanding_bytes).unwrap_or(u64::MAX), Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> TerminalInputReceiptSnapshot {
        TerminalInputReceiptSnapshot {
            submission_us: self.submission_us.snapshot(),
            ack_wait_us: self.ack_wait_us.snapshot(),
            host_write_failures: self.host_write_failures.load(Ordering::Relaxed),
            host_flush_failures: self.host_flush_failures.load(Ordering::Relaxed),
            host_ack_enqueue_rejections: self.host_ack_enqueue_rejections.load(Ordering::Relaxed),
            ack_timeouts: self.ack_timeouts.load(Ordering::Relaxed),
            last_host_write_error_kind: self
                .last_host_write_error_kind
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .as_ref()
                .map(|kind| format!("{kind:?}")),
            last_host_flush_error_kind: self
                .last_host_flush_error_kind
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .as_ref()
                .map(|kind| format!("{kind:?}")),
            last_ack_timeout_outstanding_requests: self
                .last_ack_timeout_outstanding_requests
                .load(Ordering::Relaxed),
            last_ack_timeout_outstanding_bytes: self
                .last_ack_timeout_outstanding_bytes
                .load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct TerminalInputReceiptSnapshot {
    /// Time from accepted receipt reservation through complete Input-frame
    /// submission to the terminal-host socket. This excludes the owner-ACK wait.
    pub submission_us: HistogramSnapshot,
    /// Time spent waiting after submission for the targeted owner acknowledgement.
    pub ack_wait_us: HistogramSnapshot,
    pub host_write_failures: u64,
    pub host_flush_failures: u64,
    /// PTY delivery completed, but HostTap could not queue the targeted ACK.
    pub host_ack_enqueue_rejections: u64,
    pub ack_timeouts: u64,
    pub last_host_write_error_kind: Option<String>,
    pub last_host_flush_error_kind: Option<String>,
    /// Snapshot taken before the timed-out receipt releases its reservation.
    pub last_ack_timeout_outstanding_requests: u64,
    pub last_ack_timeout_outstanding_bytes: u64,
}
''',
    '''/// Mux-side observations for receipted terminal input. Authoritative PTY
/// write/flush failures happen in the independent terminal-host process and use
/// that process's private bounded diagnostic sidecar instead of these counters.
pub struct TerminalInputReceiptStats {
    submission_us: LogLinearHistogram,
    ack_wait_us: LogLinearHistogram,
    ack_timeouts: AtomicU64,
    last_ack_timeout_outstanding_requests: AtomicU64,
    last_ack_timeout_outstanding_bytes: AtomicU64,
}

impl Default for TerminalInputReceiptStats {
    fn default() -> Self {
        Self {
            submission_us: LogLinearHistogram::new(),
            ack_wait_us: LogLinearHistogram::new(),
            ack_timeouts: AtomicU64::new(0),
            last_ack_timeout_outstanding_requests: AtomicU64::new(0),
            last_ack_timeout_outstanding_bytes: AtomicU64::new(0),
        }
    }
}

impl TerminalInputReceiptStats {
    pub(crate) fn submission_finished(&self, duration: Duration) {
        self.submission_us.record_duration(duration);
    }

    pub(crate) fn ack_wait_finished(&self, duration: Duration) {
        self.ack_wait_us.record_duration(duration);
    }

    pub(crate) fn ack_timed_out(&self, outstanding_requests: usize, outstanding_bytes: usize) {
        self.ack_timeouts.fetch_add(1, Ordering::Relaxed);
        self.last_ack_timeout_outstanding_requests
            .store(u64::try_from(outstanding_requests).unwrap_or(u64::MAX), Ordering::Relaxed);
        self.last_ack_timeout_outstanding_bytes
            .store(u64::try_from(outstanding_bytes).unwrap_or(u64::MAX), Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> TerminalInputReceiptSnapshot {
        TerminalInputReceiptSnapshot {
            submission_us: self.submission_us.snapshot(),
            ack_wait_us: self.ack_wait_us.snapshot(),
            ack_timeouts: self.ack_timeouts.load(Ordering::Relaxed),
            last_ack_timeout_outstanding_requests: self
                .last_ack_timeout_outstanding_requests
                .load(Ordering::Relaxed),
            last_ack_timeout_outstanding_bytes: self
                .last_ack_timeout_outstanding_bytes
                .load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct TerminalInputReceiptSnapshot {
    /// Time from accepted receipt reservation through complete Input-frame
    /// submission to the terminal-host socket. This excludes the owner-ACK wait.
    pub submission_us: HistogramSnapshot,
    /// Time spent waiting after submission for the targeted owner acknowledgement.
    pub ack_wait_us: HistogramSnapshot,
    pub ack_timeouts: u64,
    /// Snapshot taken before the timed-out receipt releases its reservation.
    pub last_ack_timeout_outstanding_requests: u64,
    pub last_ack_timeout_outstanding_bytes: u64,
}
''',
    "daemon terminal input stats",
)

text = replace_once(
    text,
    '''    fn terminal_input_receipt_stats_distinguish_timings_and_failure_phases() {
        let stats = TerminalInputReceiptStats::default();
        stats.submission_finished(Duration::from_micros(11));
        stats.ack_wait_finished(Duration::from_micros(29));
        stats.host_write_failed(std::io::ErrorKind::BrokenPipe);
        stats.host_flush_failed(std::io::ErrorKind::TimedOut);
        stats.host_ack_enqueue_rejected();
        stats.ack_timed_out(3, 99);

        let snapshot = stats.snapshot();
        assert_eq!(snapshot.submission_us.count, 1);
        assert_eq!(snapshot.submission_us.max, 11);
        assert_eq!(snapshot.ack_wait_us.count, 1);
        assert_eq!(snapshot.ack_wait_us.max, 29);
        assert_eq!(snapshot.host_write_failures, 1);
        assert_eq!(snapshot.host_flush_failures, 1);
        assert_eq!(snapshot.host_ack_enqueue_rejections, 1);
        assert_eq!(snapshot.ack_timeouts, 1);
        assert_eq!(snapshot.last_host_write_error_kind.as_deref(), Some("BrokenPipe"));
        assert_eq!(snapshot.last_host_flush_error_kind.as_deref(), Some("TimedOut"));
        assert_eq!(snapshot.last_ack_timeout_outstanding_requests, 3);
        assert_eq!(snapshot.last_ack_timeout_outstanding_bytes, 99);
''',
    '''    fn terminal_input_receipt_stats_distinguish_submission_ack_wait_and_timeout_pressure() {
        let stats = TerminalInputReceiptStats::default();
        stats.submission_finished(Duration::from_micros(11));
        stats.ack_wait_finished(Duration::from_micros(29));
        stats.ack_timed_out(3, 99);

        let snapshot = stats.snapshot();
        assert_eq!(snapshot.submission_us.count, 1);
        assert_eq!(snapshot.submission_us.max, 11);
        assert_eq!(snapshot.ack_wait_us.count, 1);
        assert_eq!(snapshot.ack_wait_us.max, 29);
        assert_eq!(snapshot.ack_timeouts, 1);
        assert_eq!(snapshot.last_ack_timeout_outstanding_requests, 3);
        assert_eq!(snapshot.last_ack_timeout_outstanding_bytes, 99);
''',
    "daemon terminal input stats test",
)
diagnostics.write_text(text)

runtime = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
text = runtime.read_text()

anchor = '''    fn exit_persistence_diagnostic_path(exit_record_path: &Path) -> PathBuf {
        exit_record_path.with_extension("exit-error")
    }
'''
addition = '''    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum InputReceiptDiagnosticFailure {
        PtyWrite(std_io::ErrorKind),
        PtyFlush(std_io::ErrorKind),
        AckEnqueue,
    }

    fn input_receipt_diagnostic_path(exit_record_path: &Path) -> PathBuf {
        exit_record_path.with_extension("input-error")
    }

    fn write_input_receipt_diagnostic(
        exit_record_path: &Path,
        failure: InputReceiptDiagnosticFailure,
    ) -> std_io::Result<()> {
        let path = input_receipt_diagnostic_path(exit_record_path);
        if let Some(parent) = path.parent() {
            prepare_private_dir(parent).map_err(std_io::Error::other)?;
        }
        let message = match failure {
            InputReceiptDiagnosticFailure::PtyWrite(kind) => format!(
                "terminal-host receipted-input failure; phase=pty_write_all; error_kind={kind:?}\\n"
            ),
            InputReceiptDiagnosticFailure::PtyFlush(kind) => format!(
                "terminal-host receipted-input failure; phase=pty_flush; error_kind={kind:?}\\n"
            ),
            InputReceiptDiagnosticFailure::AckEnqueue => String::from(
                "terminal-host receipted-input failure; phase=input_ack_enqueue; pty_write_flush_completed=true\\n",
            ),
        };
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        (&file).write_all(message.as_bytes())?;
        file.sync_all()
    }

    fn clear_input_receipt_diagnostic(exit_record_path: &Path) {
        match fs::remove_file(input_receipt_diagnostic_path(exit_record_path)) {
            Ok(()) => {}
            Err(error) if error.kind() == std_io::ErrorKind::NotFound => {}
            Err(_) => {}
        }
    }

'''
text = replace_once(text, anchor, addition + anchor, "host input diagnostic helpers")

text = replace_once(
    text,
    '''        let proof = liveness_path(record_path, &current);
        let endpoint = PathBuf::from(&current.endpoint);
        fs::remove_file(record_path)?;
        let _ = fs::remove_file(proof);
''',
    '''        let proof = liveness_path(record_path, &current);
        let endpoint = PathBuf::from(&current.endpoint);
        fs::remove_file(record_path)?;
        clear_input_receipt_diagnostic(record_path);
        let _ = fs::remove_file(proof);
''',
    "stale host diagnostic cleanup",
)

text = replace_once(
    text,
    '''            let removed_record =
                !self.published || (owns_record && fs::remove_file(&self.record_path).is_ok());
            let _ = fs::remove_file(&self.endpoint);
            if removed_record && let Some(path) = released_lease_path {
                let _ = fs::remove_file(path);
            }
''',
    '''            let removed_record =
                !self.published || (owns_record && fs::remove_file(&self.record_path).is_ok());
            let _ = fs::remove_file(&self.endpoint);
            if removed_record {
                clear_input_receipt_diagnostic(&self.shared.exit_record_path);
                if let Some(path) = released_lease_path {
                    let _ = fs::remove_file(path);
                }
            }
''',
    "normal host diagnostic cleanup",
)

text = replace_once(
    text,
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
            let delivered = {
                let mut writer = self.writer.lock().unwrap();
                match writer.write_all(payload) {
                    Ok(()) => writer.flush().map_err(|error| (true, error.kind())),
                    Err(error) => Err((false, error.kind())),
                }
            };
            // Interactive input has always been best-effort. Only a nonzero
            // request id asks the authoritative host to certify delivery.
            if request_id == 0 {
                return true;
            }
            if let Err((flush_failed, kind)) = delivered {
                let stats = crate::diagnostics::terminal_input_receipt_stats();
                if flush_failed {
                    stats.host_flush_failed(kind);
                } else {
                    stats.host_write_failed(kind);
                }
                return false;
            }
            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            let queued = target.try_send(response);
            if !queued {
                crate::diagnostics::terminal_input_receipt_stats().host_ack_enqueue_rejected();
            }
            queued
        }
''',
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
            let delivered = {
                let mut writer = self.writer.lock().unwrap();
                match writer.write_all(payload) {
                    Ok(()) => writer
                        .flush()
                        .map_err(|error| InputReceiptDiagnosticFailure::PtyFlush(error.kind())),
                    Err(error) => Err(InputReceiptDiagnosticFailure::PtyWrite(error.kind())),
                }
            };
            // Interactive input has always been best-effort. Only a nonzero
            // request id asks the authoritative host to certify delivery.
            if request_id == 0 {
                return true;
            }
            if let Err(failure) = delivered {
                // The host is a separate process with stderr intentionally
                // detached from the daemon. Persist only this bounded phase/error
                // summary after releasing the authoritative PTY-writer lock.
                let _ = write_input_receipt_diagnostic(&self.exit_record_path, failure);
                return false;
            }
            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            let queued = target.try_send(response);
            if !queued {
                let _ = write_input_receipt_diagnostic(
                    &self.exit_record_path,
                    InputReceiptDiagnosticFailure::AckEnqueue,
                );
            }
            queued
        }
''',
    "host write_input diagnostics destination",
)

text = replace_once(
    text,
    '''        fn host_receipted_input_partial_write_closes_connection_without_ack() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    '''        fn host_receipted_input_partial_write_closes_connection_without_ack() {
            let host = test_host_shared();
            let diagnostic = input_receipt_diagnostic_path(&host.exit_record_path);
''',
    "partial write diagnostic test pre",
)
text = replace_once(
    text,
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"fa");
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.host_write_failures >= before.host_write_failures + 1);
        }
''',
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"fa");
            let message = fs::read_to_string(&diagnostic).unwrap();
            assert!(message.contains("phase=pty_write_all"), "{message}");
            assert!(message.contains("error_kind=BrokenPipe"), "{message}");
            assert!(!message.contains("failure-path"), "{message}");
            assert_eq!(fs::metadata(&diagnostic).unwrap().permissions().mode() & 0o777, 0o600);
            let _ = fs::remove_file(diagnostic);
        }
''',
    "partial write diagnostic test post",
)

text = replace_once(
    text,
    '''        fn host_receipted_input_flush_failure_closes_connection_without_ack() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    '''        fn host_receipted_input_flush_failure_closes_connection_without_ack() {
            let host = test_host_shared();
            let diagnostic = input_receipt_diagnostic_path(&host.exit_record_path);
''',
    "flush diagnostic test pre",
)
text = replace_once(
    text,
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"failure-path");
            assert_eq!(flushes.load(Ordering::Acquire), 1);
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.host_flush_failures >= before.host_flush_failures + 1);
        }
''',
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"failure-path");
            assert_eq!(flushes.load(Ordering::Acquire), 1);
            let message = fs::read_to_string(&diagnostic).unwrap();
            assert!(message.contains("phase=pty_flush"), "{message}");
            assert!(message.contains("error_kind=BrokenPipe"), "{message}");
            assert!(!message.contains("failure-path"), "{message}");
            let _ = fs::remove_file(diagnostic);
        }
''',
    "flush diagnostic test post",
)

text = replace_once(
    text,
    '''        fn host_input_ack_total_budget_rejection_is_post_delivery_connection_loss() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    '''        fn host_input_ack_total_budget_rejection_is_post_delivery_connection_loss() {
            let host = test_host_shared();
            let diagnostic = input_receipt_diagnostic_path(&host.exit_record_path);
''',
    "ACK enqueue diagnostic test pre",
)
text = replace_once(
    text,
    '''            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.host_ack_enqueue_rejections >= before.host_ack_enqueue_rejections + 1);
        }
''',
    '''            let message = fs::read_to_string(&diagnostic).unwrap();
            assert!(message.contains("phase=input_ack_enqueue"), "{message}");
            assert!(message.contains("pty_write_flush_completed=true"), "{message}");
            assert!(!message.contains("delivered-before-ack-rejection"), "{message}");
            let _ = fs::remove_file(diagnostic);
        }
''',
    "ACK enqueue diagnostic test post",
)

runtime.write_text(text)
