#!/bin/bash
# Opt-in shared Xcode compilation cache for local reload builds.
#
# Xcode's compilation cache stores compiler output by content. By default it
# lives inside each DerivedData directory, and reload.sh gives every tag its
# own, so a build that starts from an empty DerivedData compiles everything
# again. Pointing every tag at one store lets that build replay earlier
# results instead. Entries are keyed on the DerivedData path, so the hits go
# to a tag whose derived data was deleted and to any build that reuses a
# path through --derived-data; a brand-new tag path still compiles once.
#
# It is off by default because of what it costs an edit build. With caching
# on, Swift recompiles a whole module when one of its files changes: a
# one-line edit in the cmux target went from 2 compile steps and about 50 s
# to 2,471 files and 250-320 s. Turn it on for builds that start from
# scratch, not for an edit-build loop.
#
# CMUX_COMPILATION_CACHE=1            turn it on
# CMUX_COMPILATION_CACHE_DIR=<path>   store location
# CMUX_COMPILATION_CACHE_LIMIT_BYTES  size limit Xcode enforces on the store
#
# Prints one xcodebuild build-setting argument per line; prints nothing when off.
cmux_compilation_cache_xcodebuild_args() {
  case "${CMUX_COMPILATION_CACHE:-0}" in
    1|yes|YES|true|on) ;;
    *) return 0 ;;
  esac

  local dir="${CMUX_COMPILATION_CACHE_DIR:-${HOME:-}/Library/Caches/cmux/compilation-cache}"
  case "$dir" in
    /*) ;;
    *)
      echo "error: CMUX_COMPILATION_CACHE_DIR must be an absolute path: $dir" >&2
      return 1
      ;;
  esac

  # The store rotates generations at half this limit and keeps two, so the
  # directory stays near the limit. One Debug build writes about 2.5 GB.
  local limit="${CMUX_COMPILATION_CACHE_LIMIT_BYTES:-8589934592}"
  if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CMUX_COMPILATION_CACHE_LIMIT_BYTES must be a positive integer: $limit" >&2
    return 1
  fi

  printf '%s\n' \
    "COMPILATION_CACHE_ENABLE_CACHING=YES" \
    "COMPILATION_CACHE_CAS_PATH=$dir" \
    "COMPILATION_CACHE_LIMIT_SIZE=$limit"
}
