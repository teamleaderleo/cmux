from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:180]!r}")
    p.write_text(text.replace(old, new, 1))


runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"
marker = '''        #[test]\n        fn host_input_receipt_follows_the_pty_write() {\n'''
control = '''        #[test]\n        fn interactive_input_keeps_fire_and_forget_semantics() {\n            let host = test_host_shared();\n            let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();\n            *host.writer.lock().unwrap() = Box::new(pty_writer);\n            let (target_socket, _target_peer) = UnixStream::pair().unwrap();\n            let (target_tx, target_rx) = mpsc_channel();\n            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);\n\n            assert!(host.write_input(b"x", 0, &target));\n            let mut byte = [0u8; 1];\n            pty_reader.read_exact(&mut byte).unwrap();\n            assert_eq!(&byte, b"x");\n            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());\n        }\n\n'''
replace_once(runtime, marker, control + marker)
