#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/markdown-viewer/chunks" "$TMP_DIR/markdown-viewer/nested"
printf 'const top = "top";\n' > "$TMP_DIR/markdown-viewer/top.js"
printf 'export const chunk = "chunk";\n' > "$TMP_DIR/markdown-viewer/chunks/chunk.mjs"
printf 'already compressed\n' > "$TMP_DIR/markdown-viewer/nested/keep.js.deflate"
printf 'body { color: red; }\n' > "$TMP_DIR/markdown-viewer/style.css"

"$ROOT/scripts/compress-markdown-viewer-assets.sh" "$TMP_DIR/markdown-viewer" >"$TMP_DIR/compress.log"

for path in \
  "$TMP_DIR/markdown-viewer/top.js" \
  "$TMP_DIR/markdown-viewer/chunks/chunk.mjs"
do
  if [ -e "$path" ]; then
    echo "raw JS asset was not removed: $path" >&2
    exit 1
  fi
done

for path in \
  "$TMP_DIR/markdown-viewer/top.js.deflate" \
  "$TMP_DIR/markdown-viewer/chunks/chunk.mjs.deflate"
do
  if [ ! -s "$path" ]; then
    echo "compressed asset missing or empty: $path" >&2
    exit 1
  fi
done

if [ "$(cat "$TMP_DIR/markdown-viewer/nested/keep.js.deflate")" != "already compressed" ]; then
  echo "existing .deflate asset was rewritten" >&2
  exit 1
fi

python3 - <<'PY' "$TMP_DIR/markdown-viewer"
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])
assert zlib.decompress((root / "top.js.deflate").read_bytes()) == b'const top = "top";\n'
assert zlib.decompress((root / "chunks/chunk.mjs.deflate").read_bytes()) == b'export const chunk = "chunk";\n'
PY

python3 - "$TMP_DIR/markdown-viewer" "$ROOT/scripts/compress-markdown-viewer-assets.sh" <<'PY'
import os
import pathlib
import subprocess
import sys
import zlib

root = pathlib.Path(sys.argv[1])
script = sys.argv[2]
raw = root / 'top.js'
packed = root / 'top.js.deflate'
original = zlib.decompress(packed.read_bytes())
os.utime(packed, ns=(1000000000, 1000000000))
raw.write_bytes(original)
subprocess.run([script, str(root)], check=True, stdout=subprocess.DEVNULL)
assert not raw.exists()
assert packed.stat().st_mtime_ns == 1000000000, 'unchanged compressed output was rewritten'

for content, cached in [
    (original.replace(b'top', b'new'), zlib.compress(original)),
    (original, b'corrupt'),
    (original, zlib.compress(original) + b'trailing garbage'),
    (b'small', zlib.compress(b'x' * 1000000)),
]:
    raw.write_bytes(content)
    packed.write_bytes(cached)
    subprocess.run([script, str(root)], check=True, stdout=subprocess.DEVNULL)
    assert zlib.decompress(packed.read_bytes()) == content
    assert not raw.exists()
print('PASS: unchanged assets retain output; edited and corrupt assets rebuild')

# Reproduce Xcode replacing the entire resources directory between builds.
import shutil
derived = root.parent / 'derived'
environment = dict(os.environ, DERIVED_FILE_DIR=str(derived))
raw.write_bytes(original)
packed.unlink()
subprocess.run([script, str(root)], check=True, env=environment, stdout=subprocess.DEVNULL)
cached = derived / 'cmux-markdown-compressed-v1/top.js.deflate'
os.utime(cached, ns=(1000000000, 1000000000))
shutil.rmtree(root)
root.mkdir()
raw.write_bytes(original)
subprocess.run([script, str(root)], check=True, env=environment, stdout=subprocess.DEVNULL)
assert cached.stat().st_mtime_ns == 1000000000
assert zlib.decompress(packed.read_bytes()) == original
assert not raw.exists()
for content, cached_bytes in [(b'edited source', cached.read_bytes()), (original, b'broken')]:
    packed.unlink()
    raw.write_bytes(content)
    cached.write_bytes(cached_bytes)
    subprocess.run([script, str(root)], check=True, env=environment, stdout=subprocess.DEVNULL)
    assert zlib.decompress(packed.read_bytes()) == content
    assert zlib.decompress(cached.read_bytes()) == content
print('PASS: derived cache survives resource replacement and validates edits and corruption')
PY
