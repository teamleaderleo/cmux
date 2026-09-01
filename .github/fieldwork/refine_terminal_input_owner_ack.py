from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"
replace_once(
    runtime,
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
            {
                let mut writer = self.writer.lock().unwrap();
                if writer.write_all(payload).and_then(|()| writer.flush()).is_err() {
                    return false;
                }
            }
            if request_id == 0 {
                return true;
            }
            let mut response = Frame::new(MessageKind::InputAck, Vec::new());
            response.request_id = request_id;
            let _broadcast = self.broadcast_lock.lock().unwrap();
            target.try_send(response)
        }
''',
    '''        fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
            let delivered = {
                let mut writer = self.writer.lock().unwrap();
                writer.write_all(payload).and_then(|()| writer.flush()).is_ok()
            };
            // Preserve the existing best-effort semantics for interactive clients.
            // Only a nonzero request id asks the host to make delivery authoritative.
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
)

content = "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs"
insert_before = '''fn terminal_write(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {\n'''
helper = '''fn confirmed_terminal_write(
    surface: &Surface,
    bytes: &[u8],
    operation: &str,
) -> Result<(), ActionFailure> {
    match surface.write_bytes_confirmed(bytes) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => {
            Err(ActionFailure::Known(ResourceError::operation_failed(
                operation,
                error.to_string(),
                json!({}),
            )))
        }
        Err(error) => Err(ActionFailure::Indeterminate(error.to_string())),
    }
}

'''
replace_once(content, insert_before, helper + insert_before)
replace_once(
    content,
    '''    surface
        .write_bytes_confirmed(&bytes)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
''',
    '''    confirmed_terminal_write(surface, &bytes, "terminal.input.write")
''',
)
replace_once(
    content,
    '''    surface
        .write_bytes_confirmed(&encoded)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
''',
    '''    confirmed_terminal_write(surface, &encoded, "terminal.input.keys")
''',
)
replace_once(
    content,
    '''    surface
        .write_bytes_confirmed(&output)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
''',
    '''    confirmed_terminal_write(surface, &output, "terminal.input.mouse")
''',
)
replace_once(
    content,
    '''    surface
        .write_bytes_confirmed(bytes)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
''',
    '''    confirmed_terminal_write(surface, bytes, "terminal.input.focus")
''',
)

spec = "cmux-tui/spec/terminal-host.md"
replace_once(
    spec,
    '''Discovery records use JSON `record_version:4`. Terminal and incarnation are
32-character lowercase UUIDv4 hex, owner token and process nonce are
64-character lowercase hex, the Unix-socket path is canonical, and the host
PID is nonzero. Record directories are mode `0700`; records and sockets are
''',
    '''Discovery records use JSON `record_version:4`. Terminal and incarnation are
32-character lowercase UUIDv4 hex, owner token and process nonce are
64-character lowercase hex, the Unix-socket path is canonical, and the host
PID is nonzero. `supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input must fail before sending while
legacy fire-and-forget input remains available. Record directories are mode
`0700`; records and sockets are
''',
)
