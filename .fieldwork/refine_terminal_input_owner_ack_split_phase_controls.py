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
    '''    const MAX_PENDING_INPUT_ACKS: usize = 256;\n''',
    '''    const MAX_PENDING_INPUT_ACKS: usize = 256;\n    // Keep the total outstanding receipted payload bounded too. Using the\n    // existing frame-payload ceiling preserves admission for one maximum-sized\n    // legal Input while preventing 256 such frames from accumulating.\n    const MAX_PENDING_INPUT_ACK_BYTES: usize = MAX_FRAME_PAYLOAD;\n''',
)
replace_once(
    runtime,
    '''    pub(crate) struct ControlResponses {\n        waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,\n        deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,\n        latest_cell_pixel_ack: AtomicU64,\n        pending_input_acks: AtomicUsize,\n    }\n''',
    '''    #[derive(Default)]\n    struct PendingInputAckWindow {\n        writes: usize,\n        bytes: usize,\n    }\n\n    pub(crate) struct ControlResponses {\n        waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,\n        deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,\n        latest_cell_pixel_ack: AtomicU64,\n        pending_input_acks: Mutex<PendingInputAckWindow>,\n    }\n''',
)
replace_once(
    runtime,
    '''                latest_cell_pixel_ack: AtomicU64::new(0),\n                pending_input_acks: AtomicUsize::new(0),\n''',
    '''                latest_cell_pixel_ack: AtomicU64::new(0),\n                pending_input_acks: Mutex::new(PendingInputAckWindow::default()),\n''',
)
replace_once(
    runtime,
    '''        fn try_reserve_input_ack(&self) -> bool {\n            self.pending_input_acks\n                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {\n                    (current < MAX_PENDING_INPUT_ACKS).then_some(current + 1)\n                })\n                .is_ok()\n        }\n\n        fn release_input_ack(&self) {\n            let previous = self.pending_input_acks.fetch_sub(1, Ordering::AcqRel);\n            debug_assert!(previous > 0, "terminal input ACK reservation underflow");\n        }\n\n        #[cfg(test)]\n        fn pending_input_acks_for_test(&self) -> usize {\n            self.pending_input_acks.load(Ordering::Acquire)\n        }\n''',
    '''        fn try_reserve_input_ack(&self, bytes: usize) -> bool {\n            if bytes > MAX_PENDING_INPUT_ACK_BYTES {\n                return false;\n            }\n            let mut pending = self.pending_input_acks.lock().unwrap();\n            if pending.writes >= MAX_PENDING_INPUT_ACKS\n                || bytes > MAX_PENDING_INPUT_ACK_BYTES.saturating_sub(pending.bytes)\n            {\n                return false;\n            }\n            pending.writes += 1;\n            pending.bytes += bytes;\n            true\n        }\n\n        fn release_input_ack(&self, bytes: usize) {\n            let mut pending = self.pending_input_acks.lock().unwrap();\n            debug_assert!(pending.writes > 0, "terminal input ACK reservation underflow");\n            debug_assert!(pending.bytes >= bytes, "terminal input ACK byte reservation underflow");\n            pending.writes = pending.writes.saturating_sub(1);\n            pending.bytes = pending.bytes.saturating_sub(bytes);\n        }\n\n        #[cfg(test)]\n        fn pending_input_acks_for_test(&self) -> (usize, usize) {\n            let pending = self.pending_input_acks.lock().unwrap();\n            (pending.writes, pending.bytes)\n        }\n''',
)
replace_once(
    runtime,
    '''        writer: Arc<Mutex<UnixStream>>,\n        active: bool,\n''',
    '''        writer: Arc<Mutex<UnixStream>>,\n        bytes: usize,\n        active: bool,\n''',
)
replace_once(
    runtime,
    '''                self.control_responses.release_input_ack();\n                self.active = false;\n''',
    '''                self.control_responses.release_input_ack(self.bytes);\n                self.active = false;\n''',
)
replace_once(
    runtime,
    '''            if !self.control_responses.try_reserve_input_ack() {\n''',
    '''            if !self.control_responses.try_reserve_input_ack(payload.len()) {\n''',
)
replace_once(
    runtime,
    '''                self.control_responses.release_input_ack();\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host input request id exhausted",\n''',
    '''                self.control_responses.release_input_ack(payload.len());\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host input request id exhausted",\n''',
)
replace_once(
    runtime,
    '''                    self.control_responses.release_input_ack();\n                    return Err(std::io::Error::new(\n                        std::io::ErrorKind::WouldBlock,\n                        "terminal host input request id collision",\n''',
    '''                    self.control_responses.release_input_ack(payload.len());\n                    return Err(std::io::Error::new(\n                        std::io::ErrorKind::WouldBlock,\n                        "terminal host input request id collision",\n''',
)
replace_once(
    runtime,
    '''                self.control_responses.release_input_ack();\n                return Err(error);\n''',
    '''                self.control_responses.release_input_ack(payload.len());\n                return Err(error);\n''',
)
replace_once(
    runtime,
    '''                writer: self.writer.clone(),\n                active: true,\n''',
    '''                writer: self.writer.clone(),\n                bytes: payload.len(),\n                active: true,\n''',
)
replace_once(
    runtime,
    '''            assert_eq!(control_responses.pending_input_acks_for_test(), 0);\n''',
    '''            assert_eq!(control_responses.pending_input_acks_for_test(), (0, 0));\n''',
)
replace_once(
    runtime,
    '''        fn receipted_input_window_is_bounded() {\n            let responses = ControlResponses::new();\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                assert!(responses.try_reserve_input_ack());\n            }\n            assert!(!responses.try_reserve_input_ack());\n            assert_eq!(responses.pending_input_acks_for_test(), MAX_PENDING_INPUT_ACKS);\n            responses.release_input_ack();\n            assert!(responses.try_reserve_input_ack());\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                responses.release_input_ack();\n            }\n            assert_eq!(responses.pending_input_acks_for_test(), 0);\n        }\n''',
    '''        fn receipted_input_window_is_bounded() {\n            let responses = ControlResponses::new();\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                assert!(responses.try_reserve_input_ack(1));\n            }\n            assert!(!responses.try_reserve_input_ack(1));\n            assert_eq!(\n                responses.pending_input_acks_for_test(),\n                (MAX_PENDING_INPUT_ACKS, MAX_PENDING_INPUT_ACKS)\n            );\n            responses.release_input_ack(1);\n            assert!(responses.try_reserve_input_ack(1));\n            for _ in 0..MAX_PENDING_INPUT_ACKS {\n                responses.release_input_ack(1);\n            }\n            assert_eq!(responses.pending_input_acks_for_test(), (0, 0));\n\n            assert!(responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES));\n            assert!(!responses.try_reserve_input_ack(1));\n            responses.release_input_ack(MAX_PENDING_INPUT_ACK_BYTES);\n            assert_eq!(responses.pending_input_acks_for_test(), (0, 0));\n            assert!(!responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES + 1));\n        }\n''',
)

surface = "cmux-tui/crates/cmux-tui-core/src/surface.rs"
insert_before = '''    #[test]\n    fn test_surface_accepts_non_uuid_public_terminal_identity() {\n'''
extra_test = '''    #[cfg(unix)]\n    #[test]\n    fn receipted_input_rejects_an_exited_host_before_effect() {\n        let mux = Mux::new_for_test("receipted-input-exited-host", SurfaceOptions::default());\n        let surface =\n            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();\n        let pty = surface.as_pty().unwrap();\n        {\n            let mut runtime = pty.runtime.lock().unwrap();\n            *runtime = PtyRuntime::ExitedHosted;\n        }\n\n        let error = surface.write_bytes_confirmed(b"must-not-drop").unwrap_err();\n        assert_eq!(error.kind(), std::io::ErrorKind::NotConnected);\n        assert!(error.to_string().contains("no live PTY owner"));\n    }\n\n'''
replace_once(surface, insert_before, extra_test + insert_before)
