# shellcheck shell=bash
# Disk hygiene for tagged dev builds. Sourced by reload.sh and prune-dev-builds.sh.
#
# A tagged reload owns one DerivedData directory (several GB). reload.sh never
# deletes another tag's build, because someone may still be verifying it. That
# leaves two gaps this file closes:
#   - nothing stops a build from starting on a disk that cannot hold it;
#   - nothing records who owns a build directory, so cleanup has to guess.
#
# The lease is an observation aid, not authority: prune decisions re-check live
# processes every time and treat any doubt as "keep".

CMUX_DEV_BUILD_LEASE_NAME=".cmux-reload-lease"

cmux_dev_build_derived_root() {
  echo "${CMUX_DEV_BUILD_DERIVED_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
}

cmux_dev_build_tmp_root() {
  echo "${CMUX_DEV_BUILD_TMP_ROOT:-/tmp}"
}

# Free space, in whole GB, on the volume that holds (or will hold) a path.
cmux_dev_build_free_gb() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  df -Pk "$path" 2>/dev/null | awk 'NR==2 { printf "%d\n", $4 / 1048576 }'
}

cmux_dev_build_is_warm() {
  [[ -d "$1/Build/Intermediates.noindex" ]]
}

cmux_dev_build_write_lease() {
  local derived="$1" tag="$2" worktree="$3"
  local lease="$derived/$CMUX_DEV_BUILD_LEASE_NAME"
  local tmp
  mkdir -p "$derived" || return 0
  tmp="$(mktemp "$derived/.cmux-reload-lease.XXXXXX")" || return 0
  {
    echo "tag=$tag"
    echo "pid=$$"
    echo "worktree=$worktree"
    echo "branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
    echo "started_at=$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$lease"
}

cmux_dev_build_lease_field() {
  local derived="$1" key="$2"
  local lease="$derived/$CMUX_DEV_BUILD_LEASE_NAME"
  [[ -f "$lease" ]] || return 0
  sed -n "s/^${key}=//p" "$lease" | head -n 1
}

# Tag slug for a DerivedData directory: the lease wins, else the cmux-<slug> name.
cmux_dev_build_tag() {
  local derived="$1" tag
  tag="$(cmux_dev_build_lease_field "$derived" tag)"
  if [[ -z "$tag" ]]; then
    tag="$(basename "$derived")"
    tag="${tag#cmux-}"
  fi
  echo "$tag"
}

cmux_dev_build_is_running() {
  local derived="$1" tag pid
  tag="$(cmux_dev_build_tag "$derived")"
  pid="$(cmux_dev_build_lease_field "$derived" pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if pgrep -f "cmux DEV ${tag}.app/Contents/MacOS/" >/dev/null 2>&1; then
    return 0
  fi
  # Anything else still holding the directory: an xcodebuild started outside
  # reload.sh, a test host, a debugger. reload.sh also publishes the build as
  # /tmp/cmux-<tag>, so a process may hold it under that name.
  pgrep -f "$derived/" >/dev/null 2>&1 || pgrep -f "$(cmux_dev_build_tmp_root)/cmux-${tag}/" >/dev/null 2>&1
}

# Hours since the last reload (lease mtime), else since the directory changed.
cmux_dev_build_idle_hours() {
  local derived="$1" ref now mtime
  ref="$derived/$CMUX_DEV_BUILD_LEASE_NAME"
  [[ -f "$ref" ]] || ref="$derived/Build/Products/Debug"
  [[ -e "$ref" ]] || ref="$derived"
  now="$(date +%s)"
  mtime="$(stat -f %m "$ref" 2>/dev/null || stat -c %Y "$ref" 2>/dev/null || echo "$now")"
  echo $(( (now - mtime) / 3600 ))
}

# Prints one of: running | orphan | idle | active
#   running  a process owns it right now                      -> never removable
#   orphan   the worktree that built it no longer exists      -> removable
#   idle     no reload for at least $2 hours, nothing running -> removable
#   active   everything else                                  -> keep
cmux_dev_build_status() {
  local derived="$1" idle_after_hours="${2:-24}" worktree
  if cmux_dev_build_is_running "$derived"; then
    echo running
    return
  fi
  worktree="$(cmux_dev_build_lease_field "$derived" worktree)"
  if [[ -n "$worktree" && ! -d "$worktree" ]]; then
    echo orphan
    return
  fi
  if [[ "$(cmux_dev_build_idle_hours "$derived")" -ge "$idle_after_hours" ]]; then
    echo idle
    return
  fi
  echo active
}

cmux_dev_build_list_dirs() {
  local root
  root="$(cmux_dev_build_derived_root)"
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 1 -type d -name 'cmux-*' -print 2>/dev/null | sort
}

# Refuse to start a build the disk cannot hold. A cold tagged build writes
# roughly 8-11 GB; an incremental one writes little. Returns non-zero with an
# actionable message on stderr. CMUX_RELOAD_MIN_FREE_GB=0 disables the guard.
cmux_dev_build_disk_guard() {
  local derived="$1" need free kind
  if cmux_dev_build_is_warm "$derived"; then
    kind="incremental"
    need="${CMUX_RELOAD_MIN_FREE_GB:-4}"
  else
    kind="cold"
    need="${CMUX_RELOAD_MIN_FREE_GB:-15}"
  fi
  if ! [[ "$need" =~ ^[0-9]+$ ]]; then
    echo "error: CMUX_RELOAD_MIN_FREE_GB must be a non-negative integer" >&2
    return 1
  fi
  [[ "$need" -gt 0 ]] || return 0
  free="$(cmux_dev_build_free_gb "$derived")"
  [[ -n "$free" ]] || return 0
  [[ "$free" -lt "$need" ]] || return 0

  {
    echo "error: only ${free} GB free; a ${kind} build of this tag needs ${need} GB."
    echo "  A build that runs out of disk fails late and can corrupt other running builds."
    echo "  See what is reclaimable:   ./scripts/prune-dev-builds.sh"
    echo "  Remove orphaned/idle ones: ./scripts/prune-dev-builds.sh --apply"
    echo "  Override this check:       CMUX_RELOAD_MIN_FREE_GB=0 ./scripts/reload.sh ..."
  } >&2
  return 1
}
