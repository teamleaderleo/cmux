#!/bin/sh
set -eu

MARKDOWN_VIEWER_DIR="${1:-${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer}"

if [ ! -d "$MARKDOWN_VIEWER_DIR" ]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to compress markdown viewer assets" >&2
  exit 1
fi

python3 - "$MARKDOWN_VIEWER_DIR" <<'PY'
import os
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])
# Xcode replaces the resource directory when copying source assets. Keep its
# reusable compressed copies alongside other target-specific derived files.
derived = os.environ.get("DERIVED_FILE_DIR")
cache = pathlib.Path(derived) / "cmux-markdown-compressed-v1" if derived else None

def matches(output, raw):
    try:
        # Validate content rather than mtimes: Xcode can recopy unchanged assets,
        # and a source edit can preserve size and timestamp. Bound inflation to
        # the expected source length so damaged cached output cannot expand freely.
        decoder = zlib.decompressobj()
        restored = decoder.decompress(output.read_bytes(), len(raw) + 1)
        return restored == raw and decoder.eof and not decoder.unused_data
    except (FileNotFoundError, zlib.error):
        return False

reused = 0
for path in sorted(root.rglob("*")):
    if path.suffix not in {".js", ".mjs"}:
        continue
    if path.name.endswith(".deflate"):
        continue
    raw = path.read_bytes()
    output = path.with_name(path.name + ".deflate")
    if matches(output, raw):
        path.unlink()
        reused += 1
        continue
    cached = cache / output.relative_to(root) if cache else None
    if cached is not None and matches(cached, raw):
        compressed = cached.read_bytes()
        reused += 1
    else:
        compressed = zlib.compress(raw, level=9)
        if cached is not None:
            cached.parent.mkdir(parents=True, exist_ok=True)
            cached.write_bytes(compressed)
        print(f"compressed markdown viewer asset: {path.name} -> {output.name} ({len(raw)} -> {len(compressed)} bytes)")
    output.write_bytes(compressed)
    path.unlink()
if reused:
    print(f"reused {reused} verified compressed markdown viewer assets")
PY
