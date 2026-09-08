from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"{label} anchor changed (count={text.count(old)})")
    return text.replace(old, new, 1)


diagnostics = Path("cmux-tui/crates/cmux-tui-core/src/diagnostics.rs")
text = diagnostics.read_text()
text = replace_once(
    text,
    "use std::sync::Mutex;\n",
    "use std::sync::{Mutex, OnceLock};\n",
    "diagnostics Mutex import",
)

anchor = "/// Connection admission on the control socket.\n"
addition = '''/// Receipted terminal-input observations. These counters deliberately carry no
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
        *self
            .last_host_write_error_kind
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(kind);
    }

    pub(crate) fn host_flush_failed(&self, kind: std::io::ErrorKind) {
        self.host_flush_failures.fetch_add(1, Ordering::Relaxed);
        *self
            .last_host_flush_error_kind
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(kind);
    }

    pub(crate) fn host_ack_enqueue_rejected(&self) {
        self.host_ack_enqueue_rejections.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn ack_timed_out(&self, outstanding_requests: usize, outstanding_bytes: usize) {
        self.ack_timeouts.fetch_add(1, Ordering::Relaxed);
        self.last_ack_timeout_outstanding_requests.store(
            u64::try_from(outstanding_requests).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        self.last_ack_timeout_outstanding_bytes.store(
            u64::try_from(outstanding_bytes).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
    }

    pub fn snapshot(&self) -> TerminalInputReceiptSnapshot {
        TerminalInputReceiptSnapshot {
            submission_us: self.submission_us.snapshot(),
            ack_wait_us: self.ack_wait_us.snapshot(),
            host_write_failures: self.host_write_failures.load(Ordering::Relaxed),
            host_flush_failures: self.host_flush_failures.load(Ordering::Relaxed),
            host_ack_enqueue_rejections: self
                .host_ack_enqueue_rejections
                .load(Ordering::Relaxed),
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

static TERMINAL_INPUT_RECEIPT_STATS: OnceLock<TerminalInputReceiptStats> = OnceLock::new();

pub(crate) fn terminal_input_receipt_stats() -> &'static TerminalInputReceiptStats {
    TERMINAL_INPUT_RECEIPT_STATS.get_or_init(TerminalInputReceiptStats::default)
}

'''
text = replace_once(text, anchor, addition + anchor, "connection stats")

text = replace_once(
    text,
    '''    pub journal_writer: Option<JournalWriterSnapshot>,
    pub connections: ConnectionSnapshot,
}

pub const SERVER_STATS_SCHEMA: u32 = 1;
''',
    '''    pub journal_writer: Option<JournalWriterSnapshot>,
    pub connections: ConnectionSnapshot,
    pub terminal_input_receipts: TerminalInputReceiptSnapshot,
}

pub const SERVER_STATS_SCHEMA: u32 = 2;
''',
    "server stats snapshot",
)

anchor = '''    #[test]
    fn connection_stats_enforce_the_limit_and_count_refusals() {
'''
test = '''    #[test]
    fn terminal_input_receipt_stats_distinguish_timings_and_failure_phases() {
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

        let encoded = serde_json::to_value(ServerStatsSnapshot {
            schema: SERVER_STATS_SCHEMA,
            uptime_ms: 0,
            registry_lock: LockStatsSnapshot::default(),
            journal_writer: None,
            connections: ConnectionSnapshot::default(),
            terminal_input_receipts: snapshot,
        })
        .unwrap();
        assert_eq!(encoded["schema"], SERVER_STATS_SCHEMA);
        assert!(encoded.get("terminal_input_receipts").is_some());
    }

'''
text = replace_once(text, anchor, test + anchor, "diagnostics test")
diagnostics.write_text(text)

server = Path("cmux-tui/crates/cmux-tui-core/src/server.rs")
text = server.read_text()
text = replace_once(
    text,
    '''        journal_writer: mux.journal_writer_stats(),
        connections: mux.connection_stats().snapshot(MAX_SERVER_CONNECTIONS as u64),
''',
    '''        journal_writer: mux.journal_writer_stats(),
        connections: mux.connection_stats().snapshot(MAX_SERVER_CONNECTIONS as u64),
        terminal_input_receipts: crate::diagnostics::terminal_input_receipt_stats().snapshot(),
''',
    "server_stats constructor",
)
server.write_text(text)

runtime = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
text = runtime.read_text()
text = replace_once(
    text,
    '''        #[cfg(test)]
        fn pending_input_acks_for_test(&self) -> (usize, usize) {
            let pending = self.pending_input_acks.lock().unwrap();
            (pending.writes, pending.bytes)
        }
''',
    '''        fn pending_input_acks(&self) -> (usize, usize) {
            let pending = self.pending_input_acks.lock().unwrap();
            (pending.writes, pending.bytes)
        }

        #[cfg(test)]
        fn pending_input_acks_for_test(&self) -> (usize, usize) {
            self.pending_input_acks()
        }
''',
    "pending input ACK snapshot",
)

text = replace_once(
    text,
    '''        fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
            match self.receiver.recv_timeout(timeout) {
                Ok(frame) => {
                    if !frame.payload.is_empty() {
                        self.abort_connection();
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "terminal host returned a malformed input acknowledgement",
                        ));
                    }
                    Ok(())
                }
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                    // Shutdown uses a separately cloned socket handle. A timed-out
                    // receipt therefore does not wait behind another frame writer
                    // before it can abort the broken attachment.
                    self.abort_connection();
                    let kind = match error {
                        RecvTimeoutError::Timeout => std::io::ErrorKind::TimedOut,
                        RecvTimeoutError::Disconnected => std::io::ErrorKind::ConnectionAborted,
                    };
                    Err(std::io::Error::new(
                        kind,
                        format!("terminal host did not acknowledge receipted input: {error}"),
                    ))
                }
            }
        }
''',
    '''        fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
            let wait_started = Instant::now();
            let response = self.receiver.recv_timeout(timeout);
            crate::diagnostics::terminal_input_receipt_stats()
                .ack_wait_finished(wait_started.elapsed());
            match response {
                Ok(frame) => {
                    if !frame.payload.is_empty() {
                        self.abort_connection();
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "terminal host returned a malformed input acknowledgement",
                        ));
                    }
                    Ok(())
                }
                Err(error) => {
                    let timed_out = matches!(&error, &RecvTimeoutError::Timeout);
                    if timed_out {
                        let (outstanding_requests, outstanding_bytes) =
                            self.control_responses.pending_input_acks();
                        crate::diagnostics::terminal_input_receipt_stats()
                            .ack_timed_out(outstanding_requests, outstanding_bytes);
                    }
                    self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                    // Shutdown uses a separately cloned socket handle. A timed-out
                    // receipt therefore does not wait behind another frame writer
                    // before it can abort the broken attachment.
                    self.abort_connection();
                    let kind = if timed_out {
                        std::io::ErrorKind::TimedOut
                    } else {
                        std::io::ErrorKind::ConnectionAborted
                    };
                    Err(std::io::Error::new(
                        kind,
                        format!("terminal host did not acknowledge receipted input: {error}"),
                    ))
                }
            }
        }
''',
    "InputAckReceipt wait_for",
)

text = replace_once(
    text,
    '''            if !self.control_responses.try_reserve_input_ack(payload.len()) {
                return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "terminal host receipted-input window is full",
                )));
            }

            let shutdown = self.control_responses.input_ack_shutdown_handle(&self.writer).map_err(
''',
    '''            if !self.control_responses.try_reserve_input_ack(payload.len()) {
                return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "terminal host receipted-input window is full",
                )));
            }
            let submission_started = Instant::now();

            let shutdown = self.control_responses.input_ack_shutdown_handle(&self.writer).map_err(
''',
    "confirmed input submission start",
)

text = replace_once(
    text,
    '''            let write_result = {
                let mut writer = self.writer.lock().unwrap();
                let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
                if result.is_err() {
                    let _ = writer.shutdown(std::net::Shutdown::Both);
                }
                result
            };
            if let Err(error) = write_result {
''',
    '''            let write_result = {
                let mut writer = self.writer.lock().unwrap();
                let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
                if result.is_err() {
                    let _ = writer.shutdown(std::net::Shutdown::Both);
                }
                result
            };
            crate::diagnostics::terminal_input_receipt_stats()
                .submission_finished(submission_started.elapsed());
            if let Err(error) = write_result {
''',
    "confirmed input submission finish",
)

text = replace_once(
    text,
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
            let delivered = {
                let mut writer = self.writer.lock().unwrap();
                writer.write_all(payload).and_then(|()| writer.flush()).is_ok()
            };
            // Interactive input has always been best-effort. Only a nonzero
            // request id asks the authoritative host to certify delivery.
            if request_id == 0 {
                return true;
            }
            if !delivered {
                return false;
            }
            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            target.try_send(response)
        }
''',
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
    "host write_input",
)

text = replace_once(
    text,
    '''            attachment.begin_input_confirmed(b"owner-ack").unwrap().wait().unwrap();
            responder.join().unwrap();
''',
    '''            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            attachment.begin_input_confirmed(b"owner-ack").unwrap().wait().unwrap();
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.submission_us.count >= before.submission_us.count + 1);
            assert!(after.ack_wait_us.count >= before.ack_wait_us.count + 1);
            responder.join().unwrap();
''',
    "receipt timing test",
)

text = replace_once(
    text,
    '''        fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
            let (attachment, mut host) = input_ack_surface_fixture();
            let receipt = attachment.begin_input_confirmed(b"timeout").unwrap();
''',
    '''        fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let (attachment, mut host) = input_ack_surface_fixture();
            let receipt = attachment.begin_input_confirmed(b"timeout").unwrap();
''',
    "timeout diagnostics pre",
)

text = replace_once(
    text,
    '''            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            drop(writer_guard);
            waiter.join().unwrap();
        }

        #[test]
        fn receipted_input_window_is_bounded() {
''',
    '''            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.submission_us.count >= before.submission_us.count + 1);
            assert!(after.ack_wait_us.count >= before.ack_wait_us.count + 1);
            assert!(after.ack_timeouts >= before.ack_timeouts + 1);
            assert!(after.last_ack_timeout_outstanding_requests >= 1);
            drop(writer_guard);
            waiter.join().unwrap();
        }

        #[test]
        fn receipted_input_window_is_bounded() {
''',
    "timeout diagnostics post",
)

text = replace_once(
    text,
    '''        fn host_receipted_input_partial_write_closes_connection_without_ack() {
            let host = test_host_shared();
''',
    '''        fn host_receipted_input_partial_write_closes_connection_without_ack() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    "partial-write diagnostics pre",
)

text = replace_once(
    text,
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"fa");
        }

        #[test]
        fn host_receipted_input_flush_failure_closes_connection_without_ack() {
            let host = test_host_shared();
''',
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"fa");
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.host_write_failures >= before.host_write_failures + 1);
        }

        #[test]
        fn host_receipted_input_flush_failure_closes_connection_without_ack() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    "partial/flush diagnostics",
)

text = replace_once(
    text,
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"failure-path");
            assert_eq!(flushes.load(Ordering::Acquire), 1);
        }

        #[test]
        fn host_input_ack_total_budget_rejection_is_post_delivery_connection_loss() {
            let host = test_host_shared();
''',
    '''            assert_failed_receipted_input_closes_host_connection(host);
            assert_eq!(&*accepted.lock().unwrap(), b"failure-path");
            assert_eq!(flushes.load(Ordering::Acquire), 1);
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(after.host_flush_failures >= before.host_flush_failures + 1);
        }

        #[test]
        fn host_input_ack_total_budget_rejection_is_post_delivery_connection_loss() {
            let before = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            let host = test_host_shared();
''',
    "flush/ACK-rejection diagnostics",
)

text = replace_once(
    text,
    '''                "HostTap total-budget rejection must close the attachment"
            );
        }

        #[test]
        fn terminate_waits_for_the_authoritative_host_receipt() {
''',
    '''                "HostTap total-budget rejection must close the attachment"
            );
            let after = crate::diagnostics::terminal_input_receipt_stats().snapshot();
            assert!(
                after.host_ack_enqueue_rejections >= before.host_ack_enqueue_rejections + 1
            );
        }

        #[test]
        fn terminate_waits_for_the_authoritative_host_receipt() {
''',
    "ACK-rejection diagnostics post",
)

runtime.write_text(text)
