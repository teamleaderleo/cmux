from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:180]!r}")
    p.write_text(text.replace(old, new, 1))


runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"

# InputAckReceipt is Unix-only, but the delivery classification is consumed by
# surface.rs through the parent terminal_host_runtime module. Keep the enum at
# that parent boundary instead of leaking the private unix implementation module.
replace_once(
    runtime,
    '''    #[derive(Debug)]\n    pub(crate) enum InputAckBeginFailure {\n        Known(std::io::Error),\n        Ambiguous(std::io::Error),\n    }\n\n    pub(crate) struct InputAckReceipt {\n''',
    '''    pub(crate) struct InputAckReceipt {\n''',
)
replace_once(
    runtime,
    '''#[cfg(unix)]\nmod unix {\n''',
    '''#[derive(Debug)]\npub(crate) enum InputAckBeginFailure {\n    Known(std::io::Error),\n    Ambiguous(std::io::Error),\n}\n\n#[cfg(unix)]\nmod unix {\n''',
)
