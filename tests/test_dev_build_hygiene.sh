#!/usr/bin/env bash
# Disk guard, build lease, and prune behavior for tagged dev builds.
# Hermetic: fake df/pgrep on PATH, DerivedData and /tmp redirected to a temp dir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-hygiene-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

FAKE_BIN="$ROOT/bin"
mkdir -p "$FAKE_BIN" "$ROOT/derived" "$ROOT/tmp" "$ROOT/worktrees/live"

# df reports whatever FAKE_FREE_GB says; pgrep matches only FAKE_PGREP_MATCH.
cat > "$FAKE_BIN/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 $(( ${FAKE_FREE_GB:-100} * 1048576 )) 1% /"
EOF
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/bin/sh
for last; do :; done
[ -n "${FAKE_PGREP_MATCH:-}" ] || exit 1
case "$last" in *"$FAKE_PGREP_MATCH"*) exit 0 ;; esac
exit 1
EOF
chmod +x "$FAKE_BIN/df" "$FAKE_BIN/pgrep"

export PATH="$FAKE_BIN:$PATH"
export CMUX_DEV_BUILD_DERIVED_ROOT="$ROOT/derived"
export CMUX_DEV_BUILD_TMP_ROOT="$ROOT/tmp"
unset CMUX_RELOAD_MIN_FREE_GB FAKE_PGREP_MATCH

# shellcheck source=scripts/lib/dev-build-hygiene.sh
source "$REPO_ROOT/scripts/lib/dev-build-hygiene.sh"

failures=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failures=$((failures + 1))
  fi
}
refuses() { ! "$@" 2>/dev/null; }

# A dead pid for leases whose reload has finished.
dead_pid() { ( : ) & wait $!; echo $!; }

# make_build <tag> <worktree> <hours-since-reload>
make_build() {
  local derived="$ROOT/derived/cmux-$1"
  mkdir -p "$derived/Build/Products/Debug" "$derived/Build/Intermediates.noindex"
  cmux_dev_build_write_lease "$derived" "$1" "$2"
  sed -i.bak "s/^pid=.*/pid=$(dead_pid)/" "$derived/$CMUX_DEV_BUILD_LEASE_NAME"
  rm -f "$derived/$CMUX_DEV_BUILD_LEASE_NAME.bak"
  touch -t "$(date -v-"$3"H +%Y%m%d%H%M.%S)" "$derived/$CMUX_DEV_BUILD_LEASE_NAME"
  echo "$derived"
}

# --- disk guard -------------------------------------------------------------
cold="$ROOT/derived/cmux-cold"
FAKE_FREE_GB=10 check "cold build is refused below 15 GB" refuses cmux_dev_build_disk_guard "$cold"
check "a refused build creates no directory" test ! -e "$cold"
FAKE_FREE_GB=15 check "cold build is allowed at 15 GB" cmux_dev_build_disk_guard "$cold"

warm="$(make_build warm "$ROOT/worktrees/live" 0)"
FAKE_FREE_GB=10 check "incremental build is allowed at 10 GB" cmux_dev_build_disk_guard "$warm"
FAKE_FREE_GB=3 check "incremental build is refused below 4 GB" refuses cmux_dev_build_disk_guard "$warm"
FAKE_FREE_GB=1 CMUX_RELOAD_MIN_FREE_GB=0 check "0 disables the guard" cmux_dev_build_disk_guard "$cold"
CMUX_RELOAD_MIN_FREE_GB=lots check "a non-integer threshold is an error" refuses cmux_dev_build_disk_guard "$cold"

message="$(FAKE_FREE_GB=2 cmux_dev_build_disk_guard "$cold" 2>&1 || true)"
check "the refusal names the prune command" grep -q "prune-dev-builds.sh --apply" <<<"$message"

# --- lease and status -------------------------------------------------------
status_is() { [[ "$(cmux_dev_build_status "$1" 24)" == "$2" ]]; }

check "lease records the tag" test "$(cmux_dev_build_lease_field "$warm" tag)" = "warm"
check "lease records the worktree" test "$(cmux_dev_build_lease_field "$warm" worktree)" = "$ROOT/worktrees/live"
check "recent build with a live worktree is active" status_is "$warm" active

idle="$(make_build idle "$ROOT/worktrees/live" 30)"
check "no reload for 30h is idle" status_is "$idle" idle

mkdir -p "$ROOT/worktrees/gone"
orphan="$(make_build orphan "$ROOT/worktrees/gone" 0)"
rmdir "$ROOT/worktrees/gone"
check "build whose worktree was removed is an orphan" status_is "$orphan" orphan

reloading="$(make_build reloading "$ROOT/worktrees/live" 30)"
sed -i.bak "s/^pid=.*/pid=$$/" "$reloading/$CMUX_DEV_BUILD_LEASE_NAME"
rm -f "$reloading/$CMUX_DEV_BUILD_LEASE_NAME.bak"
touch -t "$(date -v-30H +%Y%m%d%H%M.%S)" "$reloading/$CMUX_DEV_BUILD_LEASE_NAME"
check "a live reload pid wins over idle" status_is "$reloading" running

appup="$(make_build appup "$ROOT/worktrees/live" 30)"
FAKE_PGREP_MATCH="cmux DEV appup.app" check "a running tagged app wins over idle" status_is "$appup" running

legacy="$ROOT/derived/cmux-legacy"
mkdir -p "$legacy/Build/Products/Debug"
touch -t "$(date -v-40H +%Y%m%d%H%M.%S)" "$legacy/Build/Products/Debug"
check "a build without a lease falls back to directory age" status_is "$legacy" idle

# --- prune ------------------------------------------------------------------
ln -s "$idle" "$ROOT/tmp/cmux-idle"
ln -s "$warm" "$ROOT/tmp/cmux-warm"
touch "$ROOT/tmp/cmux-debug-idle.log"
export FAKE_PGREP_MATCH="cmux DEV appup.app"

"$REPO_ROOT/scripts/prune-dev-builds.sh" > "$ROOT/dry.out"
check "dry run deletes nothing" test -d "$idle" -a -d "$orphan" -a -d "$legacy"
check "dry run reports the idle build" grep -Eq "idle +.*idle" "$ROOT/dry.out"

"$REPO_ROOT/scripts/prune-dev-builds.sh" --apply > "$ROOT/apply.out"
check "apply removes the idle build" test ! -e "$idle"
check "apply removes the orphan build" test ! -e "$orphan"
check "apply removes the lease-less stale build" test ! -e "$legacy"
check "apply removes the dangling /tmp link" test ! -L "$ROOT/tmp/cmux-idle"
check "apply removes the stale debug log" test ! -e "$ROOT/tmp/cmux-debug-idle.log"
check "apply keeps the active build" test -d "$warm"
check "apply keeps the active build's /tmp link" test -L "$ROOT/tmp/cmux-warm"
check "apply keeps a build whose reload is live" test -d "$reloading"
check "apply keeps a build whose app is running" test -d "$appup"
check "source worktrees are untouched" test -d "$ROOT/worktrees/live"

"$REPO_ROOT/scripts/prune-dev-builds.sh" --apply --idle-hours 0 > /dev/null
check "--idle-hours 0 still keeps running builds" test -d "$reloading" -a -d "$appup"
check "--idle-hours 0 removes a finished recent build" test ! -e "$warm"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
