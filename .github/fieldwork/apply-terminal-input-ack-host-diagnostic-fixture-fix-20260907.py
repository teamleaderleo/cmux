from pathlib import Path

path = Path("cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor changed (count={count})")
    text = text.replace(old, new, 1)


replace_once(
    '''        fn test_host_shared() -> Arc<HostShared> {
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let (parser_commands, _parser_receiver) = sync_channel(1);
            let host = Arc::new(HostShared {
                terminal_id: TerminalId::random().unwrap(),
''',
    '''        fn test_host_shared_at(exit_record_parent: Option<&Path>) -> Arc<HostShared> {
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let (parser_commands, _parser_receiver) = sync_channel(1);
            let terminal_id = TerminalId::random().unwrap();
            let host = Arc::new(HostShared {
                terminal_id,
''',
    "test host helper signature",
)

replace_once(
    '''                exit_record_path: std::env::temp_dir().join(format!(
                    "cmux-host-test-exit-{}-{}",
                    std::process::id(),
                    RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
                )),
''',
    '''                exit_record_path: match exit_record_parent {
                    Some(parent) => parent.join(format!("{}.exit", terminal_id.to_hex())),
                    None => std::env::temp_dir().join(format!(
                        "cmux-host-test-exit-{}-{}",
                        std::process::id(),
                        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
                    )),
                },
''',
    "test host exit path",
)

replace_once(
    '''            HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
            host
        }

        fn record_fixture(name: &str) -> (PathBuf, TerminalHostRecord, HostLivenessLease) {
''',
    '''            HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
            host
        }

        fn test_host_shared() -> Arc<HostShared> {
            test_host_shared_at(None)
        }

        fn test_host_shared_with_private_exit_record() -> (Arc<HostShared>, PathBuf) {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-input-diagnostic-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            let host = test_host_shared_at(Some(&root));
            (host, root)
        }

        fn record_fixture(name: &str) -> (PathBuf, TerminalHostRecord, HostLivenessLease) {
''',
    "test host helper wrappers",
)

for label in ["partial-write", "flush", "ack-enqueue"]:
    old = '''            let host = test_host_shared();
            let diagnostic = input_receipt_diagnostic_path(&host.exit_record_path);
'''
    new = '''            let (host, diagnostic_root) = test_host_shared_with_private_exit_record();
            let diagnostic = input_receipt_diagnostic_path(&host.exit_record_path);
'''
    if old not in text:
        raise SystemExit(f"{label} private fixture anchor missing")
    text = text.replace(old, new, 1)

# Each sidecar test already removes the diagnostic file. Remove its private
# parent too so the focused suite leaves no temporary directory behind.
needle = '''            let _ = fs::remove_file(diagnostic);
'''
if text.count(needle) < 3:
    raise SystemExit("expected three sidecar cleanup anchors")
text = text.replace(
    needle,
    '''            let _ = fs::remove_file(diagnostic);
            let _ = fs::remove_dir(diagnostic_root);
''',
    3,
)

path.write_text(text)
