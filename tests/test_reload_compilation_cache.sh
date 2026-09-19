#!/usr/bin/env bash
# The shared compilation cache arguments reload.sh hands to xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/compilation-cache.sh
source "$ROOT/scripts/lib/compilation-cache.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

args() { env -i HOME=/Users/example "$@" bash -c "source '$ROOT/scripts/lib/compilation-cache.sh'; cmux_compilation_cache_xcodebuild_args"; }

# Default: off. Caching makes Swift recompile a whole module per edit.
[[ -z "$(args)" ]] || fail "caching is on by default"
for off in 0 no false off ""; do
  [[ -z "$(args CMUX_COMPILATION_CACHE="$off")" ]] || fail "CMUX_COMPILATION_CACHE=$off emits arguments"
done

# Opt in: one store under the user's caches, size-limited.
out="$(args CMUX_COMPILATION_CACHE=1)"
[[ "$out" == *"COMPILATION_CACHE_ENABLE_CACHING=YES"* ]] || fail "CMUX_COMPILATION_CACHE=1 does not enable caching"
[[ "$out" == *"COMPILATION_CACHE_CAS_PATH=/Users/example/Library/Caches/cmux/compilation-cache"* ]] \
  || fail "default store is not the shared per-user path: $out"
[[ "$out" == *"COMPILATION_CACHE_LIMIT_SIZE=8589934592"* ]] || fail "default size limit missing: $out"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 3 ]] || fail "expected one argument per line: $out"

# The store must not depend on the tag or the DerivedData path, or tags stop sharing it.
[[ "$out" != *DerivedData* ]] || fail "store path is inside DerivedData: $out"

# Overrides.
out="$(args CMUX_COMPILATION_CACHE=1 CMUX_COMPILATION_CACHE_DIR=/Volumes/fast/cas CMUX_COMPILATION_CACHE_LIMIT_BYTES=1073741824)"
[[ "$out" == *"COMPILATION_CACHE_CAS_PATH=/Volumes/fast/cas"* ]] || fail "store override ignored: $out"
[[ "$out" == *"COMPILATION_CACHE_LIMIT_SIZE=1073741824"* ]] || fail "limit override ignored: $out"

# A path with spaces stays one argument.
out="$(args CMUX_COMPILATION_CACHE=1 "CMUX_COMPILATION_CACHE_DIR=/Volumes/my disk/cas")"
[[ "$(printf '%s\n' "$out" | grep -c 'COMPILATION_CACHE_CAS_PATH=/Volumes/my disk/cas$')" == 1 ]] \
  || fail "path with spaces was split: $out"

# Bad input fails instead of silently building without a cache.
if args CMUX_COMPILATION_CACHE=1 CMUX_COMPILATION_CACHE_DIR=relative/path >/dev/null 2>&1; then fail "relative store path accepted"; fi
if args CMUX_COMPILATION_CACHE=1 CMUX_COMPILATION_CACHE_LIMIT_BYTES=lots >/dev/null 2>&1; then fail "non-numeric limit accepted"; fi

# reload.sh passes the arguments to xcodebuild, before the build action.
grep -q 'source "$SCRIPT_DIR/lib/compilation-cache.sh"' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not source the compilation cache library"
awk '/cmux_compilation_cache_xcodebuild_args/ { seen = NR } /^XCODEBUILD_ARGS\+=\(build\)/ { build = NR } END { exit !(seen && build && seen < build) }' \
  "$ROOT/scripts/reload.sh" || fail "reload.sh does not add the cache arguments before the build action"

echo "PASS: reload compilation cache arguments"
