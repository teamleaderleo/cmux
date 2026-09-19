#!/usr/bin/env bash
# List tagged dev builds and remove the ones nobody owns. Dry-run by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dev-build-hygiene.sh
source "$SCRIPT_DIR/lib/dev-build-hygiene.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/prune-dev-builds.sh [--apply] [--idle-hours <n>]

Lists every tagged dev build under DerivedData with its size and status:

  running  a reload, the tagged app, or another process is using it   kept
  active   reloaded within the idle window                            kept
  idle     nothing running and no reload for --idle-hours (default 24) removed
  orphan   the worktree that built it no longer exists                 removed

Options:
  --apply            Actually delete. Without it, nothing is removed.
  --idle-hours <n>   Idle window in hours (default 24).
  -h, --help         Show this help.

Only build output is touched: the DerivedData directory, the /tmp/cmux-<tag>
link to it, and /tmp/cmux-debug-<tag>.log. Sockets are left to reload.sh's
liveness-gated cleanup. Source checkouts are never touched.
EOF
}

APPLY=0
IDLE_HOURS=24
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --idle-hours)
      IDLE_HOURS="${2:-}"
      if ! [[ "$IDLE_HOURS" =~ ^[0-9]+$ ]]; then
        echo "error: --idle-hours requires a non-negative integer" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
  esac
done

reclaim_kb=0
kept=0
removed=0

while IFS= read -r derived; do
  [[ -n "$derived" ]] || continue
  tag="$(cmux_dev_build_tag "$derived")"
  status="$(cmux_dev_build_status "$derived" "$IDLE_HOURS")"
  size_kb="$(du -sk "$derived" 2>/dev/null | cut -f1)"
  size_gb="$(awk -v kb="${size_kb:-0}" 'BEGIN { printf "%.1f", kb / 1048576 }')"
  detail="$(cmux_dev_build_idle_hours "$derived")h since last reload"
  worktree="$(cmux_dev_build_lease_field "$derived" worktree)"
  [[ "$status" != orphan ]] || detail="worktree gone: $worktree"

  case "$status" in
    idle|orphan)
      reclaim_kb=$((reclaim_kb + ${size_kb:-0}))
      if [[ "$APPLY" -eq 1 ]]; then
        # Re-check right before deleting: a reload may have started meanwhile.
        if cmux_dev_build_is_running "$derived"; then
          printf '  %-8s %6s GB  %-32s %s\n' "running" "$size_gb" "$tag" "started during prune; kept"
          kept=$((kept + 1))
          continue
        fi
        rm -rf "$derived"
        compat_link="$(cmux_dev_build_tmp_root)/cmux-${tag}"
        if [[ -L "$compat_link" && ! -e "$compat_link" ]]; then
          rm -f "$compat_link"
        fi
        rm -f "$(cmux_dev_build_tmp_root)/cmux-debug-${tag}.log"
        removed=$((removed + 1))
        printf '  %-8s %6s GB  %-32s %s\n' "removed" "$size_gb" "$tag" "$detail"
      else
        printf '  %-8s %6s GB  %-32s %s\n' "$status" "$size_gb" "$tag" "$detail"
      fi
      ;;
    *)
      kept=$((kept + 1))
      printf '  %-8s %6s GB  %-32s %s\n' "$status" "$size_gb" "$tag" "$detail"
      ;;
  esac
done < <(cmux_dev_build_list_dirs)

reclaim_gb="$(awk -v kb="$reclaim_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')"
echo
if [[ "$APPLY" -eq 1 ]]; then
  echo "removed ${removed} build(s), ${reclaim_gb} GB; kept ${kept}."
else
  echo "reclaimable: ${reclaim_gb} GB (re-run with --apply); ${kept} build(s) in use or recent."
fi
echo "free: $(cmux_dev_build_free_gb "$(cmux_dev_build_derived_root)") GB"
