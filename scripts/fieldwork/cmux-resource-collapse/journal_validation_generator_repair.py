from pathlib import Path

path = Path("scripts/fieldwork/cmux-resource-collapse/journal_validation_instrument.py")
text = path.read_text()

old = 'harness = replace_once(harness, old_handle, new_handle, "http handler")'
new = '''harness, replacements = re.subn(
    r"async fn handle_http\\(.*?\\n}\\n\\nasync fn run_http_server\\(",
    lambda _match: new_handle + "\\nasync fn run_http_server(",
    harness,
    count=1,
    flags=re.S,
)
if replacements != 1:
    raise AssertionError(f"http handler range: expected one match, saw {replacements}")'''
if text.count(old) != 1:
    raise AssertionError("missing strict http handler replacement")
text = text.replace(old, new, 1)

old = 'harness = replace_once(harness, old_server, new_server, "http server")'
new = '''harness, replacements = re.subn(
    r"async fn run_http_server\\(.*?\\n}\\n\\nasync fn wait_for_counter\\(",
    lambda _match: new_server + "\\nasync fn wait_for_counter(",
    harness,
    count=1,
    flags=re.S,
)
if replacements != 1:
    raise AssertionError(f"http server range: expected one match, saw {replacements}")'''
if text.count(old) != 1:
    raise AssertionError("missing strict http server replacement")
text = text.replace(old, new, 1)

# The generator embeds Rust response strings inside Python strings. Preserve the
# Rust escape sequences instead of letting Python turn them into literal CRLFs.
text = text.replace(r"\r\n", r"\\r\\n")

path.write_text(text)

# The generated result object carries enough fields to exceed serde_json's
# default macro recursion limit. This is measurement-only crate metadata.
harness_path = Path("cmux-tui/crates/chatmux-relay/examples/fieldwork_journal_backlog.rs")
harness = harness_path.read_text()
if not harness.startswith("#![recursion_limit"):
    harness_path.write_text('#![recursion_limit = "256"]\n' + harness)
