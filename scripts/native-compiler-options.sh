#!/bin/bash
# Shared opt-in build experiments for Glaeda checks and full tagged reloads.
cmux_native_compiler_options() {
  CMUX_NATIVE_XCODE_ARGS=()
  local swift_flags="${1:-}"
  case "${CMUX_BUILD_FILE_HASHING:-0}" in
    0) ;;
    1) swift_flags="$swift_flags -enable-incremental-file-hashing" ;;
    *) echo "error: CMUX_BUILD_FILE_HASHING must be 0 or 1" >&2; return 64 ;;
  esac
  if [[ -n "$swift_flags" ]]; then
    CMUX_NATIVE_XCODE_ARGS+=("OTHER_SWIFT_FLAGS=\$(inherited) $swift_flags")
  fi
  case "${CMUX_BUILD_COMPILATION_CACHE:-0}" in
    0) ;;
    1) CMUX_NATIVE_XCODE_ARGS+=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_LIMIT_SIZE=3221225472 COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES) ;;
    *) echo "error: CMUX_BUILD_COMPILATION_CACHE must be 0 or 1" >&2; return 64 ;;
  esac
}
