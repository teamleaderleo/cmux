from pathlib import Path

path = Path("cmux-tui/crates/cmux-tui-core/src/surface.rs")
text = path.read_text()
old = "                lifetime: PtyLifetime::DaemonOwned,\n                terminal_public_id: None,\n                resource_identity: None,\n"
new = "                lifetime: PtyLifetime::SessionOwned,\n                terminal_public_id: None,\n                resource_identity: None,\n"
count = text.count(old)
if count != 1:
    raise SystemExit(f"hosted ACK reader test lifetime: expected 1 match, found {count}")
path.write_text(text.replace(old, new, 1))
