from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:180]!r}")
    p.write_text(text.replace(old, new, 1))


content = "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs"
replace_once(
    content,
    '''        Err(crate::surface::ConfirmedInputFailure::Known(error)) => {\n            Err(ActionFailure::Known(ResourceError::operation_failed(\n                operation,\n                error.to_string(),\n                json!({}),\n            )))\n        }\n''',
    '''        Err(crate::surface::ConfirmedInputFailure::Known(error)) => Err(ActionFailure::Known(\n            ResourceError::operation_failed(operation, error.to_string(), json!({})),\n        )),\n''',
)

surface = "cmux-tui/crates/cmux-tui-core/src/surface.rs"
replace_once(
    surface,
    '''    pub(crate) fn write_bytes_confirmed(\n        &self,\n        bytes: &[u8],\n    ) -> Result<(), ConfirmedInputFailure> {\n''',
    '''    pub(crate) fn write_bytes_confirmed(&self, bytes: &[u8]) -> Result<(), ConfirmedInputFailure> {\n''',
)
replace_once(
    surface,
    '''                let receipt = host.begin_input_confirmed(bytes).map_err(|failure| match failure {\n                    crate::terminal_host_runtime::InputAckBeginFailure::Known(error) => {\n                        ConfirmedInputFailure::Known(error)\n                    }\n                    crate::terminal_host_runtime::InputAckBeginFailure::Ambiguous(error) => {\n                        ConfirmedInputFailure::Indeterminate(error)\n                    }\n                })?;\n''',
    '''                let receipt =\n                    host.begin_input_confirmed(bytes).map_err(|failure| match failure {\n                        crate::terminal_host_runtime::InputAckBeginFailure::Known(error) => {\n                            ConfirmedInputFailure::Known(error)\n                        }\n                        crate::terminal_host_runtime::InputAckBeginFailure::Ambiguous(error) => {\n                            ConfirmedInputFailure::Indeterminate(error)\n                        }\n                    })?;\n''',
)

runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"
replace_once(
    runtime,
    '''                waiters.insert(\n                    request_id,\n                    ControlResponseWaiter::Blocking {\n                        kind: MessageKind::InputAck,\n                        sender,\n                    },\n                );\n''',
    '''                waiters.insert(\n                    request_id,\n                    ControlResponseWaiter::Blocking { kind: MessageKind::InputAck, sender },\n                );\n''',
)
replace_once(
    runtime,
    '''            attachment\n                .begin_input_confirmed(b"owner-ack")\n                .unwrap()\n                .wait()\n                .unwrap();\n''',
    '''            attachment.begin_input_confirmed(b"owner-ack").unwrap().wait().unwrap();\n''',
)
