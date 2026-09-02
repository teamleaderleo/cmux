#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(relative: str, old: str, new: str) -> None:
    path = ROOT / relative
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{relative}: expected exactly one source match, found {count}")
    path.write_text(text.replace(old, new, 1))


# Wire kind and the protocol's numeric stability test.
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_protocol.rs",
    """    DetachAck = 22,\n    Input = 100,\n""",
    """    DetachAck = 22,\n    /// Targeted confirmation that `Input` crossed the authoritative host's PTY write/flush boundary.\n    InputAck = 23,\n    Input = 100,\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_protocol.rs",
    """            22 => Ok(Self::DetachAck),\n            100 => Ok(Self::Input),\n""",
    """            22 => Ok(Self::DetachAck),\n            23 => Ok(Self::InputAck),\n            100 => Ok(Self::Input),\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_protocol.rs",
    """        assert_eq!(MessageKind::DetachAck as u16, 22);\n        assert_eq!(MessageKind::try_from(22).unwrap(), MessageKind::DetachAck);\n        assert_eq!(MessageKind::Terminate as u16, 104);\n""",
    """        assert_eq!(MessageKind::DetachAck as u16, 22);\n        assert_eq!(MessageKind::try_from(22).unwrap(), MessageKind::DetachAck);\n        assert_eq!(MessageKind::InputAck as u16, 23);\n        assert_eq!(MessageKind::try_from(23).unwrap(), MessageKind::InputAck);\n        assert_eq!(MessageKind::Terminate as u16, 104);\n""",
)

# Record v5 is the capability fence: v4 surviving hosts never receive a
# targeted Input they cannot acknowledge.
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs",
    "const HOST_RECORD_VERSION: u32 = 4;\n",
    "const HOST_RECORD_VERSION: u32 = 5;\nconst CONFIRMED_INPUT_RECORD_VERSION: u32 = 5;\n",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs",
    """        pub fn send(&self, kind: MessageKind, payload: &[u8]) -> std::io::Result<()> {\n            let mut writer = self.writer.lock().unwrap();\n            let mut frame = Frame::new(kind, payload.to_vec());\n            frame.version = self.protocol_version;\n            let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);\n            if result.is_err() {\n                // A timed-out write may have emitted only part of a frame.\n                // Poison this connection so the reader takes a fresh atomic\n                // Snapshot instead of ever appending to a corrupt stream.\n                let _ = writer.shutdown(std::net::Shutdown::Both);\n            }\n            result\n        }\n\n        /// Update the authoritative parser defaults on a feature-advertising\n""",
    """        pub fn send(&self, kind: MessageKind, payload: &[u8]) -> std::io::Result<()> {\n            let mut writer = self.writer.lock().unwrap();\n            let mut frame = Frame::new(kind, payload.to_vec());\n            frame.version = self.protocol_version;\n            let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);\n            if result.is_err() {\n                // A timed-out write may have emitted only part of a frame.\n                // Poison this connection so the reader takes a fresh atomic\n                // Snapshot instead of ever appending to a corrupt stream.\n                let _ = writer.shutdown(std::net::Shutdown::Both);\n            }\n            result\n        }\n\n        /// Deliver a receipted input mutation through the authoritative PTY owner.\n        /// Interactive frontend input keeps using `send(Input, ...)`; only callers\n        /// that will persist success wait for this targeted owner acknowledgement.\n        pub fn send_confirmed_input(&self, payload: &[u8]) -> std::io::Result<()> {\n            if self.record.record_version < CONFIRMED_INPUT_RECORD_VERSION {\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::Unsupported,\n                    \"terminal host does not support confirmed input delivery\",\n                ));\n            }\n            let response = self\n                .send_control_request(MessageKind::Input, MessageKind::InputAck, payload.to_vec())\n                .map_err(|failure| std::io::Error::other(failure.into_error().to_string()))?;\n            if !response.is_empty() {\n                self.disconnect();\n                return Err(std::io::Error::new(\n                    std::io::ErrorKind::InvalidData,\n                    \"terminal host returned a malformed input acknowledgement\",\n                ));\n            }\n            Ok(())\n        }\n\n        /// Update the authoritative parser defaults on a feature-advertising\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs",
    """                    MessageKind::Input => {\n                        if !granted_rights.contains(CapabilityRights::INPUT) {\n                            break;\n                        }\n                        let mut writer = command_host.writer.lock().unwrap();\n                        let _ = writer.write_all(&frame.payload);\n                        let _ = writer.flush();\n                    }\n""",
    """                    MessageKind::Input => {\n                        if !granted_rights.contains(CapabilityRights::INPUT) {\n                            break;\n                        }\n                        let mut writer = command_host.writer.lock().unwrap();\n                        if writer.write_all(&frame.payload).and_then(|()| writer.flush()).is_err() {\n                            break;\n                        }\n                        drop(writer);\n                        if frame.request_id != 0 {\n                            let mut response = Frame::new(MessageKind::InputAck, Vec::new());\n                            response.request_id = frame.request_id;\n                            let _broadcast = command_host.broadcast_lock.lock().unwrap();\n                            if !command_sender.try_send(response) {\n                                break;\n                            }\n                        }\n                    }\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs",
    """        if !matches!(record.record_version, 1 | 2 | 3 | HOST_RECORD_VERSION) {\n""",
    """        if !matches!(record.record_version, 1 | 2 | 3 | 4 | HOST_RECORD_VERSION) {\n""",
)

# Surface keeps ordinary interactive input unchanged. Resource mutations use
# the confirmed path and the existing reader resolves InputAck like other
# targeted control responses.
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/surface.rs",
    """                            MessageKind::Capability\n                                | MessageKind::CellPixelSizeAck\n""",
    """                            MessageKind::Capability\n                                | MessageKind::InputAck\n                                | MessageKind::CellPixelSizeAck\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/surface.rs",
    """            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Ok(()),\n        }\n    }\n\n    /// Write a protocol input payload, conditionally applying bracketed-paste\n""",
    """            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Ok(()),\n        }\n    }\n\n    /// Write input bytes and wait until a durable host has crossed its PTY\n    /// write/flush boundary. Local PTYs already execute that boundary inline.\n    pub fn write_bytes_confirmed(&self, bytes: &[u8]) -> std::io::Result<()> {\n        let Some(pty) = self.as_pty() else {\n            return Err(std::io::Error::new(\n                std::io::ErrorKind::Unsupported,\n                \"browser surface does not accept PTY bytes\",\n            ));\n        };\n        let mut runtime = pty.runtime.lock().unwrap();\n        match &mut *runtime {\n            PtyRuntime::Local { writer, .. } => {\n                writer.write_all(bytes)?;\n                writer.flush()\n            }\n            #[cfg(unix)]\n            PtyRuntime::Hosted(host) => host.send_confirmed_input(bytes),\n            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Ok(()),\n        }\n    }\n\n    /// Write a protocol input payload, conditionally applying bracketed-paste\n""",
)

# Every receipted terminal input operation that ultimately writes PTY bytes
# uses the same owner-confirmed boundary. An adopted v4 host is rejected before
# any bytes are sent, so that compatibility case is a known non-delivery.
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs",
    """    surface.write_bytes(&bytes).map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n}\n\nfn terminal_scroll_viewport(\n""",
    """    confirmed_terminal_write(surface, &bytes, \"terminal.input.write\")\n}\n\nfn confirmed_terminal_write(\n    surface: &Surface,\n    bytes: &[u8],\n    operation: &str,\n) -> Result<(), ActionFailure> {\n    surface.write_bytes_confirmed(bytes).map_err(|error| {\n        if error.kind() == std::io::ErrorKind::Unsupported {\n            ActionFailure::Known(ResourceError::operation_failed(\n                operation,\n                \"terminal host must be restarted before receipted input can be confirmed\",\n                json!({\"reason\":\"confirmed_input_unsupported\"}),\n            ))\n        } else {\n            ActionFailure::Indeterminate(error.to_string())\n        }\n    })\n}\n\nfn terminal_scroll_viewport(\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs",
    """    surface.write_bytes(&encoded).map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n}\n""",
    """    confirmed_terminal_write(surface, &encoded, \"terminal.input.keys\")\n}\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs",
    """    surface.write_bytes(&output).map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n}\n\nfn terminal_focus(\n""",
    """    confirmed_terminal_write(surface, &output, \"terminal.input.mouse\")\n}\n\nfn terminal_focus(\n""",
)
replace_once(
    "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs",
    """    surface.write_bytes(bytes).map_err(|error| ActionFailure::Indeterminate(error.to_string()))\n}\n\nfn browser_key(\n""",
    """    confirmed_terminal_write(surface, bytes, \"terminal.input.focus\")\n}\n\nfn browser_key(\n""",
)

# Protocol documentation: frame protocol remains v4; the discovery record
# version advances because the new durable capability changes owner semantics.
replace_once(
    "cmux-tui/spec/terminal-host.md",
    "| 22 | `DetachAck` | host to client | response | empty; final source-ordered frame for this client |\n| 100 | `Input` | client to host | `INPUT` | raw PTY bytes |\n",
    "| 22 | `DetachAck` | host to client | response | empty; final source-ordered frame for this client |\n| 23 | `InputAck` | host to client | response | empty; confirms the host completed the PTY write and flush for targeted `Input` |\n| 100 | `Input` | client to host | `INPUT` | raw PTY bytes |\n",
)
replace_once(
    "cmux-tui/spec/terminal-host.md",
    """`ResizeAck.result_flags & 1` means the request changed canonical geometry;\nother bits are invalid. Acknowledgements require negotiated\n`FLAG_VIEWER_SIZE_ACKS` and a nonzero request id. Without acknowledgements,\n`ViewerSize` uses the broadcast `Resized` plus `Colors` path.\n""",
    """`ResizeAck.result_flags & 1` means the request changed canonical geometry;\nother bits are invalid. Viewer-size acknowledgements require negotiated\n`FLAG_VIEWER_SIZE_ACKS` and a nonzero request id. Without acknowledgements,\n`ViewerSize` uses the broadcast `Resized` plus `Colors` path.\n\nA targeted `Input` has a nonzero request id and receives `InputAck` only after\nthe host's authoritative PTY writer completes both `write_all` and `flush`.\nInteractive input keeps request id zero and remains fire-and-forget. Discovery\nrecord v5 is the capability fence; a newer mux must not send targeted input to\na surviving v4 host.\n""",
)
replace_once(
    "cmux-tui/spec/terminal-host.md",
    "Discovery records use JSON `record_version:4`.",
    "Discovery records use JSON `record_version:5`.",
)

print("terminal input owner-ack transform applied")
