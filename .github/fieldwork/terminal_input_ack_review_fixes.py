from pathlib import Path
import re

runtime_path = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
surface_path = Path("cmux-tui/crates/cmux-tui-core/src/surface.rs")
mux_path = Path("cmux-tui/crates/cmux-tui-core/src/mux.rs")

runtime = runtime_path.read_text()
surface = surface_path.read_text()
mux = mux_path.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# Preserve atomic physical enqueueing of coupled Output/Colors pairs.
runtime = replace_once(
    runtime,
    """            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            target.try_send(response)
""",
    """            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            let _broadcast = self.broadcast_lock.lock().unwrap();
            target.try_send(response)
""",
    "InputAck broadcast lock",
)

# Let the timeout regression use a short deadline without changing production policy.
runtime = replace_once(
    runtime,
    """        pub(crate) fn wait(self) -> std::io::Result<()> {
            match self.receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT) {
""",
    """        pub(crate) fn wait(self) -> std::io::Result<()> {
            self.wait_for(CONTROL_RESPONSE_TIMEOUT)
        }

        fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
            match self.receiver.recv_timeout(timeout) {
""",
    "InputAckReceipt wait_for",
)

# Remove the pointer-identity-only shutdown helper.
runtime, count = re.subn(
    r"""\n        #\[cfg\(test\)\]\n        fn input_ack_shutdown_is_cached_for_test\(&self, writer: &Mutex<UnixStream>\) \{.*?\n        \}\n""",
    "\n",
    runtime,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"shutdown cache helper: expected one match, found {count}")

# Add the minimal hosted-Surface fixture next to the existing record fixture.
fixture = r'''
        pub(crate) fn input_ack_surface_fixture() -> (HostAttachment, UnixStream) {
            let terminal_id = TerminalId::random().unwrap();
            let incarnation = HostIncarnation::random().unwrap();
            let owner = CapabilityToken::random().unwrap();
            let nonce = CapabilityToken::random().unwrap();
            let record = TerminalHostRecord {
                record_version: HOST_RECORD_VERSION,
                terminal_id: terminal_id.to_hex(),
                incarnation: incarnation.to_hex(),
                endpoint: "/tmp/cmux-input-ack-surface-test.sock".into(),
                owner_token: encode_hex(owner.as_bytes()),
                host_pid: std::process::id(),
                host_start_nonce: encode_hex(nonce.as_bytes()),
                workspace_key: String::new(),
                supports_set_defaults: false,
                supports_clear_history: false,
                supports_terminate_ack: false,
                supports_input_ack: true,
            };
            let record_path = std::env::temp_dir().join(format!(
                "cmux-input-ack-surface-{}-{}.json",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let (client, host) = UnixStream::pair().unwrap();
            let reader = client.try_clone().unwrap();
            let attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: false,
                reader: Some(reader),
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            (attachment, host)
        }

'''
runtime = replace_once(
    runtime,
    """        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
""",
    fixture
    + """        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
""",
    "Surface fixture insertion",
)

# Drop the attachment-only positive receipt test: the Surface test supersedes it.
runtime, count = re.subn(
    r"""\n        #\[test\]\n        fn receipted_input_waits_for_the_authoritative_pty_receipt\(\) \{.*?\n        \}\n\n(?=        #\[test\]\n        fn receipted_input_never_reaches_a_legacy_host_without_ack_support)""",
    "\n",
    runtime,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"direct positive receipt test: expected one match, found {count}")

# Replace direct waiter pipelining + cache identity with actual timeout behavior.
timeout_test = r'''
        #[test]
        fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
            let (attachment, mut host) = input_ack_surface_fixture();
            host.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let receipt = attachment.begin_input_confirmed(b"timeout").unwrap();
            let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
            assert_eq!(request.kind, MessageKind::Input);
            assert_ne!(request.request_id, 0);

            let writer_guard = attachment.writer.lock().unwrap();
            let (result_tx, result_rx) = sync_channel(1);
            let waiter = thread::spawn(move || {
                result_tx.send(receipt.wait_for(Duration::from_millis(20))).unwrap();
            });
            let error = result_rx
                .recv_timeout(Duration::from_millis(250))
                .expect("input ACK timeout blocked behind the socket writer mutex")
                .unwrap_err();
            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            assert!(
                read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().is_none(),
                "timeout shutdown did not reach the peer while the socket writer mutex was held"
            );
            drop(writer_guard);
            waiter.join().unwrap();
        }

'''
runtime, count = re.subn(
    r"""\n        #\[test\]\n        fn receipted_input_requests_can_pipeline_before_the_first_ack\(\) \{.*?\n        \}\n\n        #\[test\]\n        fn receipted_input_shutdown_handle_is_connection_scoped\(\) \{.*?\n        \}\n\n(?=        #\[test\]\n        fn receipted_input_window_is_bounded)""",
    "\n" + timeout_test,
    runtime,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"pipeline/cache tests: expected one match, found {count}")

# Replace the synchronous host test with explicit write and flush gates, plus a compact
# failing-flush case using the same writer.
host_tests = r'''
        struct GatedInputWriter {
            write_started: SyncSender<()>,
            write_release: Receiver<()>,
            flush_started: SyncSender<()>,
            flush_release: Receiver<()>,
            fail_flush: bool,
        }

        impl Write for GatedInputWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.write_started.send(()).unwrap();
                self.write_release.recv().unwrap();
                Ok(bytes.len())
            }

            fn flush(&mut self) -> std::io::Result<()> {
                self.flush_started.send(()).unwrap();
                self.flush_release.recv().unwrap();
                if self.fail_flush {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "synthetic flush failure",
                    ));
                }
                Ok(())
            }
        }

        #[test]
        fn host_input_receipt_follows_pty_write_and_flush() {
            let host = test_host_shared();
            let (write_started_tx, write_started_rx) = sync_channel(0);
            let (write_release_tx, write_release_rx) = sync_channel(0);
            let (flush_started_tx, flush_started_rx) = sync_channel(0);
            let (flush_release_tx, flush_release_rx) = sync_channel(0);
            *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
                write_started: write_started_tx,
                write_release: write_release_rx,
                flush_started: flush_started_tx,
                flush_release: flush_release_rx,
                fail_flush: false,
            });
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            let worker_host = host.clone();
            let worker_target = target.clone();
            let worker = thread::spawn(move || {
                assert!(worker_host.write_input(b"x", 42, &worker_target));
            });

            write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            write_release_tx.send(()).unwrap();
            flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            flush_release_tx.send(()).unwrap();

            let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(ack.kind, MessageKind::InputAck);
            assert_eq!(ack.request_id, 42);
            assert!(ack.payload.is_empty());
            worker.join().unwrap();
        }

        #[test]
        fn host_input_receipt_requires_successful_flush() {
            let host = test_host_shared();
            let (write_started_tx, write_started_rx) = sync_channel(0);
            let (write_release_tx, write_release_rx) = sync_channel(0);
            let (flush_started_tx, flush_started_rx) = sync_channel(0);
            let (flush_release_tx, flush_release_rx) = sync_channel(0);
            *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
                write_started: write_started_tx,
                write_release: write_release_rx,
                flush_started: flush_started_tx,
                flush_release: flush_release_rx,
                fail_flush: true,
            });
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            let worker_host = host.clone();
            let worker_target = target.clone();
            let worker = thread::spawn(move || worker_host.write_input(b"x", 42, &worker_target));

            write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            write_release_tx.send(()).unwrap();
            flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            flush_release_tx.send(()).unwrap();

            assert!(!worker.join().unwrap());
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
        }

'''
runtime, count = re.subn(
    r"""\n        #\[test\]\n        fn host_input_receipt_follows_the_pty_write\(\) \{.*?\n        \}\n\n(?=        #\[test\]\n        fn terminate_waits_for_the_authoritative_host_receipt)""",
    "\n" + host_tests,
    runtime,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"host receipt test: expected one match, found {count}")

# Re-export the fixture only for tests.
runtime = replace_once(
    runtime,
    """    }
}

#[cfg(unix)]
pub use unix::{
""",
    """    }

    #[cfg(test)]
    pub(crate) use tests::input_ack_surface_fixture;
}

#[cfg(unix)]
pub use unix::{
""",
    "fixture unix re-export",
)
runtime = replace_once(
    runtime,
    """#[cfg(all(unix, test))]
pub(crate) use unix::{
    acquire_terminal_host_publication_lock, prepare_terminal_host_publication_lock,
};
""",
    """#[cfg(all(unix, test))]
pub(crate) use unix::{
    acquire_terminal_host_publication_lock, input_ack_surface_fixture,
    prepare_terminal_host_publication_lock,
};
""",
    "fixture crate re-export",
)

# Add the tiny registry seed used by the real hosted Surface fixture.
seed = r'''
    #[cfg(all(test, unix))]
    pub(crate) fn seed_launching_terminal_for_test(
        &self,
        terminal_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-launching-terminal",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )?;
        Ok(())
    }

'''
marker = """    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test"""
if mux.count(marker) != 1:
    raise SystemExit(f"mux seed marker: expected one match, found {mux.count(marker)}")
mux = mux.replace(marker, seed + marker, 1)

# Replace the helper-only classifier test with one production Surface/socket test that
# proves reader dispatch, split-phase runtime locking, waiter identity, and interactive input.
surface, count = re.subn(
    r"""\n    #\[cfg\(unix\)\]\n    #\[test\]\n    fn input_ack_wire_frame_is_classified_before_live_staging\(\) \{.*?\n    \}\n\n(?=    #\[cfg\(unix\)\]\n    #\[test\]\n    fn hosted_stager_exposes_coupled_state_only_after_colors)""",
    "\n",
    surface,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"classifier test: expected one match, found {count}")

surface_test = r'''
    #[cfg(unix)]
    #[test]
    fn hosted_receipted_input_requests_pipeline_through_surface_reader() {
        let mux = Mux::new_for_test("hosted-input-ack-pipeline", SurfaceOptions::default());
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
        let terminal_id = attachment.record.terminal_id.clone();
        attachment.record.workspace_key = workspace.key.clone();
        mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();

        let surface = Surface::spawn_hosted(
            1,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation: None,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: None,
                resource_identity: None,
            },
        )
        .unwrap();

        host.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        host.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
        let read_input = |host: &mut std::os::unix::net::UnixStream| {
            let frame = crate::terminal_host_protocol::read_frame(
                host,
                crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
            )
            .expect("observe submitted input while the earlier ACK is withheld")
            .expect("hosted connection remains open while awaiting input ACKs");
            assert_eq!(frame.kind, MessageKind::Input);
            frame
        };

        std::thread::scope(|scope| {
            let first = scope.spawn(|| surface.write_bytes_confirmed(b"pipeline-a"));
            let first_request = read_input(&mut host);
            assert_eq!(first_request.payload, b"pipeline-a");
            assert_ne!(first_request.request_id, 0);

            let second = scope.spawn(|| surface.write_bytes_confirmed(b"pipeline-b"));
            let second_request = read_input(&mut host);
            assert_eq!(second_request.payload, b"pipeline-b");
            assert_ne!(second_request.request_id, 0);
            assert_ne!(first_request.request_id, second_request.request_id);

            let interactive = scope.spawn(|| surface.write_bytes(b"pipeline-interactive"));
            let interactive_request = read_input(&mut host);
            assert_eq!(interactive_request.payload, b"pipeline-interactive");
            assert_eq!(interactive_request.request_id, 0);
            interactive.join().unwrap().unwrap();
            assert!(!first.is_finished());
            assert!(!second.is_finished());

            let mut second_ack = Frame::new(MessageKind::InputAck, Vec::new());
            second_ack.request_id = second_request.request_id;
            crate::terminal_host_protocol::write_frame(&mut host, &second_ack).unwrap();
            second.join().unwrap().unwrap();
            assert!(!first.is_finished(), "B's ACK must leave A pending");

            let mut first_ack = Frame::new(MessageKind::InputAck, Vec::new());
            first_ack.request_id = first_request.request_id;
            crate::terminal_host_protocol::write_frame(&mut host, &first_ack).unwrap();
            first.join().unwrap().unwrap();
        });
    }

'''
surface = replace_once(
    surface,
    """    #[cfg(unix)]
    #[test]
    fn hosted_stager_exposes_coupled_state_only_after_colors() {
""",
    surface_test
    + """    #[cfg(unix)]
    #[test]
    fn hosted_stager_exposes_coupled_state_only_after_colors() {
""",
    "Surface pipeline insertion",
)

runtime_path.write_text(runtime)
surface_path.write_text(surface)
mux_path.write_text(mux)
