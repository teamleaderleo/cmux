from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:160]!r}")
    p.write_text(text.replace(old, new, 1))


runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"
replace_once(
    runtime,
    '''    const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);\n''',
    '''    const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);\n    // Match the remote PTY bridge's bounded outstanding-write precedent.\n    // This protects the local control-response waiter table from an unbounded\n    // burst of durable API input without serializing every receipt.\n    const MAX_PENDING_INPUT_ACKS: usize = 256;\n''',
)

replace_once(
    runtime,
    '''    pub(crate) struct ControlResponses {\n        waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,\n        deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,\n        latest_cell_pixel_ack: AtomicU64,\n    }\n''',
    '''    pub(crate) struct ControlResponses {\n        waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,\n        deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,\n        latest_cell_pixel_ack: AtomicU64,\n        pending_input_acks: AtomicUsize,\n    }\n''',
)
replace_once(
    runtime,
    '''                deferred_cell_pixel_handler: Mutex::new(None),\n                latest_cell_pixel_ack: AtomicU64::new(0),\n            }\n''',
    '''                deferred_cell_pixel_handler: Mutex::new(None),\n                latest_cell_pixel_ack: AtomicU64::new(0),\n                pending_input_acks: AtomicUsize::new(0),\n            }\n''',
)
replace_once(
    runtime,
    '''        fn defer_cell_pixel(&self, request_id: u64, expected: (u16, u16)) -> bool {\n''',
    '''        fn try_reserve_input_ack(&self) -> bool {\n            self.pending_input_acks\n                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {\n                    (current < MAX_PENDING_INPUT_ACKS).then_some(current + 1)\n                })\n                .is_ok()\n        }\n\n        fn release_input_ack(&self) {\n            let previous = self.pending_input_acks.fetch_sub(1, Ordering::AcqRel);\n            debug_assert!(previous > 0, "terminal input ACK reservation underflow");\n        }\n\n        #[cfg(test)]\n        fn pending_input_acks_for_test(&self) -> usize {\n            self.pending_input_acks.load(Ordering::Acquire)\n        }\n\n        fn defer_cell_pixel(&self, request_id: u64, expected: (u16, u16)) -> bool {\n''',
)

replace_once(
    runtime,
    '''    pub struct HostAttachment {\n''',
    '''    pub(crate) struct InputAckReceipt {\n        request_id: u64,\n        receiver: Option<Receiver<Frame>>,\n        control_responses: Arc<ControlResponses>,\n        writer: Arc<Mutex<UnixStream>>,\n        active: bool,\n    }\n\n    impl InputAckReceipt {\n        fn complete(&mut self) {\n            if self.active {\n                self.control_responses.release_input_ack();\n                self.active = false;\n            }\n        }\n\n        pub(crate) fn wait(mut self) -> std::io::Result<()> {\n            let receiver = self.receiver.take().expect("input ACK receiver is present");\n            let response = receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT);\n            match response {\n                Ok(frame) => {\n                    if !frame.payload.is_empty() {\n                        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);\n                        self.complete();\n                        return Err(std::io::Error::new(\n                            std::io::ErrorKind::InvalidData,\n                            "terminal host returned a malformed input acknowledgement",\n                        ));\n                    }\n                    self.complete();\n                    Ok(())\n                }\n                Err(error) => {\n                    self.control_responses.waiters.lock().unwrap().remove(&self.request_id);\n                    let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);\n                    self.complete();\n                    let kind = match error {\n                        RecvTimeoutError::Timeout => std::io::ErrorKind::TimedOut,\n                        RecvTimeoutError::Disconnected => std::io::ErrorKind::ConnectionAborted,\n                    };\n                    Err(std::io::Error::new(\n                        kind,\n                        format!("terminal host did not acknowledge receipted input: {error}"),\n                    ))\n                }\n            }\n        }\n    }\n\n    impl Drop for InputAckReceipt {\n        fn drop(&mut self) {\n            if self.active {\n                self.control_responses.waiters.lock().unwrap().remove(&self.request_id);\n                self.complete();\n            }\n        }\n    }\n\n    pub struct HostAttachment {\n''',
)

replace_once(
    runtime,
    '''        pub(crate) fn send_input_confirmed(&self, payload: &[u8]) -> std::io::Result<()> {\n            if !self.record.supports_input_ack {\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::Unsupported,\n                    "terminal host cannot acknowledge receipted input",\n                ));\n            }\n            let response = self\n                .send_control_request(MessageKind::Input, MessageKind::InputAck, payload.to_vec())\n                .map_err(|failure| std::io::Error::other(failure.into_error()))?;\n            if !response.is_empty() {\n                self.disconnect();\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::InvalidData,\n                    "terminal host returned a malformed input acknowledgement",\n                ));\n            }\n            Ok(())\n        }\n''',
    '''        pub(crate) fn begin_input_confirmed(\n            &self,\n            payload: &[u8],\n        ) -> std::io::Result<InputAckReceipt> {\n            if !self.record.supports_input_ack {\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::Unsupported,\n                    "terminal host cannot acknowledge receipted input",\n                ));\n            }\n            if !self.control_responses.try_reserve_input_ack() {\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host receipted-input window is full",\n                ));\n            }\n\n            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);\n            if request_id == 0 {\n                self.control_responses.release_input_ack();\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host input request id exhausted",\n                ));\n            }\n            let (sender, receiver) = sync_channel(1);\n            {\n                let mut waiters = self.control_responses.waiters.lock().unwrap();\n                if waiters.contains_key(&request_id) {\n                    self.control_responses.release_input_ack();\n                    return Err(std::io::Error::new(\n                        std::io::ErrorKind::WouldBlock,\n                        "terminal host input request id collision",\n                    ));\n                }\n                waiters.insert(\n                    request_id,\n                    ControlResponseWaiter::Blocking {\n                        kind: MessageKind::InputAck,\n                        sender,\n                    },\n                );\n            }\n\n            let mut frame = Frame::new(MessageKind::Input, payload.to_vec());\n            frame.version = self.protocol_version;\n            frame.request_id = request_id;\n            let write_result = {\n                let mut writer = self.writer.lock().unwrap();\n                let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);\n                if result.is_err() {\n                    let _ = writer.shutdown(std::net::Shutdown::Both);\n                }\n                result\n            };\n            if let Err(error) = write_result {\n                self.control_responses.waiters.lock().unwrap().remove(&request_id);\n                self.control_responses.release_input_ack();\n                return Err(error);\n            }\n\n            Ok(InputAckReceipt {\n                request_id,\n                receiver: Some(receiver),\n                control_responses: self.control_responses.clone(),\n                writer: self.writer.clone(),\n                active: true,\n            })\n        }\n''',
)

replace_once(
    runtime,
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {\n            {\n                let mut writer = self.writer.lock().unwrap();\n                if writer.write_all(payload).and_then(|()| writer.flush()).is_err() {\n                    return false;\n                }\n            }\n            if request_id == 0 {\n                return true;\n            }\n            let mut response = Frame::new(MessageKind::InputAck, Vec::new());\n            response.request_id = request_id;\n            let _broadcast = self.broadcast_lock.lock().unwrap();\n            target.try_send(response)\n        }\n''',
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {\n            let delivered = {\n                let mut writer = self.writer.lock().unwrap();\n                writer.write_all(payload).and_then(|()| writer.flush()).is_ok()\n            };\n            // Interactive input has always been best-effort. Only a nonzero\n            // request id asks the authoritative host to certify delivery.\n            if request_id == 0 {\n                return true;\n            }\n            if !delivered {\n                return false;\n            }\n            let mut response = Frame::new(MessageKind::InputAck, Vec::new());\n            response.request_id = request_id;\n            target.try_send(response)\n        }\n''',
)

# Convert the existing ACK tests to the split-phase API.
replace_once(
    runtime,
    '''            attachment.send_input_confirmed(b"owner-ack").unwrap();\n''',
    '''            attachment\n                .begin_input_confirmed(b"owner-ack")\n                .unwrap()\n                .wait()\n                .unwrap();\n''',
)
replace_once(
    runtime,
    '''            let error = attachment.send_input_confirmed(b"must-not-send").unwrap_err();\n            assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);\n''',
    '''            let error = match attachment.begin_input_confirmed(b"must-not-send") {\n                Ok(_) => panic!("legacy host accepted a receipted input request"),\n                Err(error) => error,\n            };\n            assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);\n''',
)

replace_once(
    runtime,
    '''        #[test]\n        fn host_input_receipt_follows_the_pty_write() {\n''',
    '''        #[test]\n        fn receipted_input_requests_can_pipeline_before_the_first_ack() {\n            let (record_path, record, lease) = record_fixture("input-ack-pipeline");\n            let root = record_path.parent().unwrap().to_path_buf();\n            let (client, mut host) = UnixStream::pair().unwrap();\n            let control_responses = Arc::new(ControlResponses::new());\n            let attachment = HostAttachment {\n                record,\n                record_path,\n                snapshot: HostSnapshot {\n                    cols: 80,\n                    rows: 24,\n                    cell_pixels: DEFAULT_CELL_PIXELS,\n                    replay: Vec::new(),\n                    kitty_image_aliases: Vec::new(),\n                    kitty_state: test_kitty_state(),\n                    sequence_boundary: 0,\n                    colors: TerminalColorOverrides::default(),\n                    pid: None,\n                    command: Vec::new(),\n                    cwd: None,\n                },\n                protocol_version: PROTOCOL_VERSION,\n                smart_renderer: true,\n                reader: None,\n                writer: Arc::new(Mutex::new(client)),\n                control_responses: control_responses.clone(),\n                next_request: AtomicU64::new(2),\n                viewer_size: Mutex::new(None),\n                launch_process: None,\n                launch_activation_pending: false,\n            };\n\n            let first = attachment.begin_input_confirmed(b"a").unwrap();\n            let first_request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();\n            assert_eq!(first_request.kind, MessageKind::Input);\n            assert_eq!(first_request.payload, b"a");\n\n            // The second request must enter the host channel before the first\n            // receipt is acknowledged. A stop-and-wait implementation cannot\n            // reach this point without resolving first_request.\n            let second = attachment.begin_input_confirmed(b"b").unwrap();\n            let second_request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();\n            assert_eq!(second_request.kind, MessageKind::Input);\n            assert_eq!(second_request.payload, b"b");\n            assert_ne!(first_request.request_id, second_request.request_id);\n\n            let mut second_ack = Frame::new(MessageKind::InputAck, Vec::new());\n            second_ack.request_id = second_request.request_id;\n            assert!(control_responses.resolve(&second_ack));\n            let mut first_ack = Frame::new(MessageKind::InputAck, Vec::new());\n            first_ack.request_id = first_request.request_id;\n            assert!(control_responses.resolve(&first_ack));\n\n            second.wait().unwrap();\n            first.wait().unwrap();\n            assert_eq!(control_responses.pending_input_acks_for_test(), 0);\n\n            drop(attachment);\n            drop(lease);\n            let _ = fs::remove_dir_all(root);\n        }\n\n        #[test]\n        fn receipted_input_window_is_bounded() {\n            let responses = ControlResponses::new();\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                assert!(responses.try_reserve_input_ack());\n            }\n            assert!(!responses.try_reserve_input_ack());\n            assert_eq!(responses.pending_input_acks_for_test(), MAX_PENDING_INPUT_ACKS);\n            responses.release_input_ack();\n            assert!(responses.try_reserve_input_ack());\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                responses.release_input_ack();\n            }\n            assert_eq!(responses.pending_input_acks_for_test(), 0);\n        }\n\n        #[test]\n        fn host_input_receipt_follows_the_pty_write() {\n''',
)

surface = "cmux-tui/crates/cmux-tui-core/src/surface.rs"
replace_once(
    surface,
    '''    /// Write receipted input bytes and wait for the authoritative hosted PTY owner.\n    ///\n    /// Ordinary interactive input keeps using `write_bytes`; this path exists for\n    /// resource mutations whose durable success receipt must follow host delivery.\n    pub(crate) fn write_bytes_confirmed(&self, bytes: &[u8]) -> std::io::Result<()> {\n        let Some(pty) = self.as_pty() else {\n            return Err(std::io::Error::new(\n                std::io::ErrorKind::Unsupported,\n                "browser surface does not accept PTY bytes",\n            ));\n        };\n        let mut runtime = pty.runtime.lock().unwrap();\n        match &mut *runtime {\n            PtyRuntime::Local { writer, .. } => {\n                writer.write_all(bytes)?;\n                writer.flush()\n            }\n            #[cfg(unix)]\n            PtyRuntime::Hosted(host) => host.send_input_confirmed(bytes),\n            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Ok(()),\n        }\n    }\n''',
    '''    /// Write receipted input bytes and wait for authoritative PTY-owner delivery.\n    ///\n    /// Hosted input registers and writes its targeted request while holding the\n    /// short runtime lock, then releases that lock before waiting for `InputAck`.\n    /// Other receipted writes can therefore enter the host channel while an\n    /// earlier caller is waiting. Interactive input continues to use `write_bytes`.\n    pub(crate) fn write_bytes_confirmed(&self, bytes: &[u8]) -> std::io::Result<()> {\n        let Some(pty) = self.as_pty() else {\n            return Err(std::io::Error::new(\n                std::io::ErrorKind::Unsupported,\n                "browser surface does not accept PTY bytes",\n            ));\n        };\n        let mut runtime = pty.runtime.lock().unwrap();\n        match &mut *runtime {\n            PtyRuntime::Local { writer, .. } => {\n                writer.write_all(bytes)?;\n                writer.flush()\n            }\n            #[cfg(unix)]\n            PtyRuntime::Hosted(host) => {\n                let receipt = host.begin_input_confirmed(bytes)?;\n                drop(runtime);\n                receipt.wait()\n            }\n            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Err(std::io::Error::new(\n                std::io::ErrorKind::NotConnected,\n                "terminal has no live PTY owner for receipted input",\n            )),\n        }\n    }\n''',
)

content = "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs"
insert_before = '''fn terminal_write(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {\n'''
helper = '''fn confirmed_terminal_write(\n    surface: &Surface,\n    bytes: &[u8],\n    operation: &str,\n) -> Result<(), ActionFailure> {\n    match surface.write_bytes_confirmed(bytes) {\n        Ok(()) => Ok(()),\n        Err(error)\n            if matches!(\n                error.kind(),\n                std::io::ErrorKind::Unsupported\n                    | std::io::ErrorKind::WouldBlock\n                    | std::io::ErrorKind::NotConnected\n            ) =>\n        {\n            Err(ActionFailure::Known(ResourceError::operation_failed(\n                operation,\n                error.to_string(),\n                json!({}),\n            )))\n        }\n        Err(error) => Err(ActionFailure::Indeterminate(error.to_string())),\n    }\n}\n\n'''
replace_once(content, insert_before, helper + insert_before)
replace_once(
    content,
    '''    surface\n        .write_bytes_confirmed(&bytes)\n        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n''',
    '''    confirmed_terminal_write(surface, &bytes, "terminal.input.write")\n''',
)
replace_once(
    content,
    '''    surface\n        .write_bytes_confirmed(&encoded)\n        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n''',
    '''    confirmed_terminal_write(surface, &encoded, "terminal.input.keys")\n''',
)
replace_once(
    content,
    '''    surface\n        .write_bytes_confirmed(&output)\n        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n''',
    '''    confirmed_terminal_write(surface, &output, "terminal.input.mouse")\n''',
)
replace_once(
    content,
    '''    surface\n        .write_bytes_confirmed(bytes)\n        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n''',
    '''    confirmed_terminal_write(surface, bytes, "terminal.input.focus")\n''',
)

spec = "cmux-tui/spec/terminal-host.md"
replace_once(
    spec,
    '''Discovery records use JSON `record_version:4`. Terminal and incarnation are\n32-character lowercase UUIDv4 hex, owner token and process nonce are\n64-character lowercase hex, the Unix-socket path is canonical, and the host\nPID is nonzero. Record directories are mode `0700`; records and sockets are\n''',
    '''Discovery records use JSON `record_version:4`. Terminal and incarnation are\n32-character lowercase UUIDv4 hex, owner token and process nonce are\n64-character lowercase hex, the Unix-socket path is canonical, and the host\nPID is nonzero. `supports_input_ack` is an additive boolean capability; a\nmissing or false value means receipted API input must fail before sending while\nlegacy fire-and-forget input remains available. Record directories are mode\n`0700`; records and sockets are\n''',
)
