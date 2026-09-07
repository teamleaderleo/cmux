from pathlib import Path

mux_path = Path("cmux-tui/crates/cmux-tui-core/src/mux.rs")
surface_path = Path("cmux-tui/crates/cmux-tui-core/src/surface.rs")
runtime_path = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
spec_path = Path("cmux-tui/spec/terminal-host.md")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    return text.replace(old, new, 1)


# Test-only helper: seed the same durable Launching record that production
# spawn_hosted expects before a SessionOwned terminal-host mirror attaches.
mux = mux_path.read_text()
mux_anchor = """    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test(
"""
mux_helper = r'''    #[cfg(all(test, unix))]
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
mux = replace_once(mux, mux_anchor, mux_helper + mux_anchor, "Mux Launching fixture helper")
mux_path.write_text(mux)

# Replace the classifier-only test with a full production-reader round trip.
surface = surface_path.read_text()
old_surface_test = r'''    #[cfg(unix)]
    #[test]
    fn input_ack_wire_frame_is_classified_before_live_staging() {
        let (mut sender, mut receiver) = std::os::unix::net::UnixStream::pair().unwrap();
        let mut ack = Frame::new(MessageKind::InputAck, Vec::new());
        ack.request_id = 42;
        crate::terminal_host_protocol::write_frame(&mut sender, &ack).unwrap();

        let decoded = crate::terminal_host_protocol::read_frame(
            &mut receiver,
            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
        )
        .unwrap()
        .unwrap();
        assert_eq!(decoded.kind, MessageKind::InputAck);
        assert_eq!(decoded.request_id, 42);
        assert!(is_targeted_host_response(decoded.kind));
        assert!(
            HostedFrameStager::new(0, true).push(decoded).is_err(),
            "a targeted InputAck would corrupt the live stream if dispatch missed it"
        );
    }
'''
new_surface_test = r'''    #[cfg(unix)]
    #[test]
    fn hosted_receipted_input_ack_round_trips_through_surface_reader() {
        let mux = Mux::new_for_test("hosted-input-ack-reader", SurfaceOptions::default());
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (mut attachment, mut host) =
            crate::terminal_host_runtime::input_ack_surface_fixture();
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

        let (observed_tx, observed_rx) = sync_channel(0);
        let (release_tx, release_rx) = sync_channel(0);
        let host_thread = std::thread::spawn(move || {
            let request = crate::terminal_host_protocol::read_frame(
                &mut host,
                crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
            )
            .unwrap()
            .unwrap();
            assert_eq!(request.kind, MessageKind::Input);
            assert_eq!(request.payload, b"owner-reader-ack");
            assert_ne!(request.request_id, 0);

            let mut ack = Frame::new(MessageKind::InputAck, Vec::new());
            ack.version = PROTOCOL_VERSION;
            ack.request_id = request.request_id;
            crate::terminal_host_protocol::write_frame(&mut host, &ack).unwrap();

            let interactive = crate::terminal_host_protocol::read_frame(
                &mut host,
                crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
            )
            .unwrap()
            .unwrap();
            assert_eq!(interactive.kind, MessageKind::Input);
            assert_eq!(interactive.payload, b"still-connected");
            assert_eq!(interactive.request_id, 0);
            observed_tx.send(()).unwrap();
            let _ = release_rx.recv_timeout(Duration::from_secs(1));
        });

        surface.write_bytes_confirmed(b"owner-reader-ack").unwrap();
        surface.write_bytes(b"still-connected").unwrap();
        observed_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("Surface reader did not preserve the hosted connection after InputAck");
        release_tx.send(()).unwrap();
        host_thread.join().unwrap();
    }
'''
surface = replace_once(surface, old_surface_test, new_surface_test, "production Surface ACK regression")
surface_path.write_text(surface)

runtime = runtime_path.read_text()

# Keep the connection-scoped cached shutdown handle from 9d9e, but make the
# receipt timeout injectable for a focused lock-independence regression.
old_wait = r'''        pub(crate) fn wait(self) -> std::io::Result<()> {
            match self.receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT) {
'''
new_wait = r'''        pub(crate) fn wait(self) -> std::io::Result<()> {
            self.wait_for(CONTROL_RESPONSE_TIMEOUT)
        }

        fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
            match self.receiver.recv_timeout(timeout) {
'''
runtime = replace_once(runtime, old_wait, new_wait, "receipt wait helper")

# A minimal HostAttachment fixture with a real reader socket for surface.rs.
fixture_anchor = """            (record_path, record, lease)
        }

        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
"""
fixture = r'''            (record_path, record, lease)
        }

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

        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
'''
runtime = replace_once(runtime, fixture_anchor, fixture, "Surface HostAttachment fixture")

# Prove timeout cleanup does not wait for the same writer mutex held by a
# concurrent submission.
timeout_anchor = """        #[test]
        fn receipted_input_window_is_bounded() {
"""
timeout_test = r'''        #[test]
        fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
            let (attachment, mut host) = input_ack_surface_fixture();
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
            drop(writer_guard);
            waiter.join().unwrap();
        }

'''
if timeout_anchor not in runtime:
    raise SystemExit("timeout regression anchor missing")
runtime = runtime.replace(timeout_anchor, timeout_test + timeout_anchor, 1)

# Strengthen ordering evidence: no ACK while either PTY write or flush is
# blocked; exactly one targeted ACK after both complete.
old_order_test = r'''        #[test]
        fn host_input_receipt_follows_the_pty_write() {
            let host = test_host_shared();
            let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();
            *host.writer.lock().unwrap() = Box::new(pty_writer);
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

            assert!(host.write_input(b"x", 42, &target));
            let mut byte = [0u8; 1];
            pty_reader.read_exact(&mut byte).unwrap();
            assert_eq!(&byte, b"x");
            let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(ack.kind, MessageKind::InputAck);
            assert_eq!(ack.request_id, 42);
            assert!(ack.payload.is_empty());
        }
'''
new_order_test = r'''        struct GatedInputWriter {
            write_started: SyncSender<()>,
            write_release: Receiver<()>,
            flush_started: SyncSender<()>,
            flush_release: Receiver<()>,
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
'''
runtime = replace_once(runtime, old_order_test, new_order_test, "write+flush ACK ordering test")

# Expose only the test fixture to surface.rs.
tail_anchor = r'''            assert_eq!(frames[output + 2].sequence, frames[output].sequence + 2);
        }
    }
}

#[cfg(unix)]
pub(crate) use unix::{
'''
tail_replacement = r'''            assert_eq!(frames[output + 2].sequence, frames[output].sequence + 2);
        }
    }

    #[cfg(test)]
    pub(crate) use tests::input_ack_surface_fixture;
}

#[cfg(unix)]
pub(crate) use unix::{
'''
runtime = replace_once(runtime, tail_anchor, tail_replacement, "unix test fixture re-export")
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
    "outer test fixture re-export",
)
runtime_path.write_text(runtime)

# Clarify the exact certificate and the deliberate timeout availability policy.
spec = spec_path.read_text()
old_contract = """PID is nonzero. `supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input must fail before sending while
legacy fire-and-forget input remains available. Record directories are mode
"""
new_contract = """PID is nonzero. `supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input that would emit PTY bytes must
fail before sending while legacy fire-and-forget input remains available. A
resource operation whose defined encoding emits no PTY bytes may still succeed
as a no-op. An input-ACK timeout is an observation deadline, not cancellation:
the host may already be completing the PTY write. The frontend poisons that
attachment after the deadline so unresolved receipts become indeterminate and
the mirror reconnects rather than accepting an unresolved late ACK.
Record directories are mode
"""
spec = replace_once(spec, old_contract, new_contract, "terminal-host input ACK contract")
spec_path.write_text(spec)
