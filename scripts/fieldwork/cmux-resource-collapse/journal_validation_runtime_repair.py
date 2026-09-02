from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: journal_validation_runtime_repair.py <harness-path>")

path = Path(sys.argv[1])
text = path.read_text()
old = '''    let root = std::env::temp_dir().join(format!("cmux-fieldwork-journal-{}-{nonce}", std::process::id()));
'''
new = '''    // Keep the fieldwork Unix-domain socket path below macOS SUN_LEN.
    let root = PathBuf::from("/tmp").join(format!("jfw-{}-{nonce:x}", std::process::id()));
'''
if text.count(old) != 1:
    raise AssertionError(f"temporary_root replacement expected one match, saw {text.count(old)}")
path.write_text(text.replace(old, new, 1))
