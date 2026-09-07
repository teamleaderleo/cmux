from pathlib import Path

surface_path = Path("cmux-tui/crates/cmux-tui-core/src/surface.rs")
runtime_path = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
spec_path = Path("cmux-tui/spec/terminal-host.md")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    return text.replace(old, new, 1)


surface = surface_path.read_text()
surface = replace_once(
    surface,
    """                                | MessageKind::TerminateAck
                                | MessageKind::DetachAck
""",
    """                                | MessageKind::TerminateAck
                                | MessageKind::DetachAck
                                | MessageKind::InputAck
""",
    "InputAck targeted dispatch",
)

surface_test_anchor = """    #[cfg(unix)]
    #[test]
    fn receipted_input_rejects_an_exited_host_before_effect() {
"""
surface_test = r'''    #[cfg(unix)]
    #[test]
    fn hosted_receipted_input_ack_round_trips_through_surface_reader() {
        let mux = Mux::new_for_test("hosted-input-ack-reader", SurfaceOptions::default());
        let (attachment, mut host) =
            crate::terminal_host_runtime::input_ack_surface_fixture();
        let surface = Surface::spawn_hosted(
            1,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation: None,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::DaemonOwned,
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
            .expect("surface reader did not preserve the hosted connection after InputAck");
        release_tx.send(()).unwrap();
        host_thread.join().unwrap();
    }

'''
if surface_test_anchor not in surface:
    raise SystemExit("surface test anchor missing")
surface = surface.replace(surface_test_anchor, surface_test + surface_test_anchor, 1)
surface_path.write_text(surface)

runtime = runtime_path.read_text()
old_receipt = r'''    pub(crate) struct InputAckReceipt {
        request_id: u64,
        receiver: Option<Receiver<Frame>>,
        control_responses: Arc<ControlResponses>,
        writer: Arc<Mutex<UnixStream>>,
        bytes: usize,
        active: bool,
    }

    impl InputAckReceipt {
        fn complete(&mut self) {
            if self.active {
                self.control_responses.release_input_ack(self.bytes);
                self.active = false;
            }
        }

        pub(crate) fn wait(mut self) -> std::io::Result<()> {
            let receiver = self.receiver.take().expect("input ACK receiver is present");
            let response = receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT);
            match response {
                Ok(frame) => {
                    if !frame.payload.is_empty() {
                        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
                        self.complete();
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "terminal host returned a malformed input acknowledgement",
                        ));
                    }
                    self.complete();
                    Ok(())
                }
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                    let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
                    self.complete();
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
    }

    impl Drop for InputAckReceipt {
        fn drop(&mut self) {
            if self.active {
                self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                self.complete();
            }
        }
    }
'''
new_receipt = r'''    pub(crate) struct InputAckReceipt {
        request_id: u64,
        receiver: Receiver<Frame>,
        control_responses: Arc<ControlResponses>,
        shutdown: Arc<UnixStream>,
        bytes: usize,
    }

    impl InputAckReceipt {
        pub(crate) fn wait(self) -> std::io::Result<()> {
            self.wait_for(CONTROL_RESPONSE_TIMEOUT)
        }

        fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
            let response = self.receiver.recv_timeout(timeout);
            match response {
                Ok(frame) => {
                    if !frame.payload.is_empty() {
                        let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "terminal host returned a malformed input acknowledgement",
                        ));
                    }
                    Ok(())
                }
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                    // Do not wait behind another sender's writer mutex to abort
                    // this attachment. The cloned handle names the same socket.
                    let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
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
    }

    impl Drop for InputAckReceipt {
        fn drop(&mut self) {
            self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
            self.control_responses.release_input_ack(self.bytes);
        }
    }
'''
runtime = replace_once(runtime, old_receipt, new_receipt, "receipt ownership")

runtime = replace_once(
    runtime,
    """        reader: Option<UnixStream>,
        writer: Arc<Mutex<UnixStream>>,
        control_responses: Arc<ControlResponses>,
""",
    """        reader: Option<UnixStream>,
        shutdown: Arc<UnixStream>,
        writer: Arc<Mutex<UnixStream>>,
        control_responses: Arc<ControlResponses>,
""",
    "HostAttachment shutdown field",
)

runtime = replace_once(
    runtime,
    """            Ok(InputAckReceipt {
                request_id,
                receiver: Some(receiver),
                control_responses: self.control_responses.clone(),
                writer: self.writer.clone(),
                bytes: payload.len(),
                active: true,
            })
""",
    """            Ok(InputAckReceipt {
                request_id,
                receiver,
                control_responses: self.control_responses.clone(),
                shutdown: self.shutdown.clone(),
                bytes: payload.len(),
            })
""",
    "receipt construction",
)

runtime = replace_once(
    runtime,
    """        pub fn disconnect(&self) {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
        }
""",
    """        pub fn disconnect(&self) {
            let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
        }
""",
    "attachment disconnect",
)

runtime = replace_once(
    runtime,
    """        let reader = stream.try_clone()?;
        let attachment = HostAttachment {
""",
    """        let reader = stream.try_clone()?;
        let shutdown = Arc::new(stream.try_clone()?);
        let attachment = HostAttachment {
""",
    "production shutdown clone",
)
runtime = replace_once(
    runtime,
    """            reader: Some(reader),
            writer: Arc::new(Mutex::new(stream)),
""",
    """            reader: Some(reader),
            shutdown,
            writer: Arc::new(Mutex::new(stream)),
""",
    "production attachment shutdown",
)

old_none = """                reader: None,
                writer: Arc::new(Mutex::new(client)),
"""
count_none = runtime.count(old_none)
if count_none < 1:
    raise SystemExit("no test HostAttachment reader:None/client literals found")
runtime = runtime.replace(
    old_none,
    """                reader: None,
                shutdown: Arc::new(client.try_clone().unwrap()),
                writer: Arc::new(Mutex::new(client)),
""",
)
old_some = """                reader: Some(reader),
                writer: Arc::new(Mutex::new(client)),
"""
count_some = runtime.count(old_some)
runtime = runtime.replace(
    old_some,
    """                reader: Some(reader),
                shutdown: Arc::new(client.try_clone().unwrap()),
                writer: Arc::new(Mutex::new(client)),
""",
)
print(f"updated test attachment literals: reader=None {count_none}, reader=Some {count_some}")

helper_anchor = """            (record_path, record, lease)
        }

        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
"""
helper = r'''            (record_path, record, lease)
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
            let shutdown = Arc::new(client.try_clone().unwrap());
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
                shutdown,
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
runtime = replace_once(runtime, helper_anchor, helper, "surface attachment fixture")

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
    raise SystemExit("timeout test anchor missing")
runtime = runtime.replace(timeout_anchor, timeout_test + timeout_anchor, 1)

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
runtime = replace_once(runtime, old_order_test, new_order_test, "write/flush ordering test")

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
runtime = replace_once(runtime, tail_anchor, tail_replacement, "test helper re-export")
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
    "outer test helper re-export",
)
runtime_path.write_text(runtime)

spec = spec_path.read_text()
capability = """PID is nonzero. `supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input must fail before sending while
legacy fire-and-forget input remains available. Record directories are mode
"""
replacement = """PID is nonzero. `supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input that would emit PTY bytes must
fail before sending while legacy fire-and-forget input remains available. A
resource operation whose defined encoding emits no PTY bytes may still succeed
as a no-op. An input-ACK timeout is an observation deadline, not cancellation:
the host may already be completing the PTY write, and the frontend poisons that
attachment so unresolved receipts become indeterminate and the mirror reconnects.
Record directories are mode
"""
spec = replace_once(spec, capability, replacement, "terminal host contract wording")
spec_path.write_text(spec)
