#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: macos_process_sampler.sh <pid> <output.csv> [interval_seconds]

Samples one macOS process without injecting code into it. The output tracks
resident memory, thread count, descriptor/socket counts, and descendants over
time so a scaling run can measure its knee and cleanup convergence.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

pid="$1"
out="$2"
interval="${3:-0.5}"

if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  echo "pid must be numeric" >&2
  exit 2
fi

mkdir -p "$(dirname "$out")"
printf '%s\n' 'epoch_s,pid,rss_kib,threads,fds,sockets,unix_sockets,direct_children,descendants' >"$out"

count_descendants() {
  local root="$1"
  ps -axo pid=,ppid= | awk -v root="$root" '
    {
      pid[NR]=$1; ppid[NR]=$2
    }
    END {
      known[root]=1
      changed=1
      while (changed) {
        changed=0
        for (i=1; i<=NR; i++) {
          if (!known[pid[i]] && known[ppid[i]]) {
            known[pid[i]]=1
            descendants++
            changed=1
          }
        }
      }
      print descendants+0
    }
  '
}

while kill -0 "$pid" 2>/dev/null; do
  epoch="$(python3 - <<'PY'
import time
print(f"{time.time():.6f}")
PY
)"
  rss="$(ps -o rss= -p "$pid" | awk '{print $1+0}')"
  threads="$(ps -M -p "$pid" 2>/dev/null | awk 'NR>1 {n++} END {print n+0}')"

  lsof_output="$(lsof -nP -p "$pid" 2>/dev/null || true)"
  fds="$(printf '%s\n' "$lsof_output" | awk 'NR>1 {n++} END {print n+0}')"
  sockets="$(printf '%s\n' "$lsof_output" | awk 'NR>1 && ($5=="IPv4" || $5=="IPv6") {n++} END {print n+0}')"
  unix_sockets="$(printf '%s\n' "$lsof_output" | awk 'NR>1 && $5=="unix" {n++} END {print n+0}')"

  direct_children="$(ps -axo ppid= | awk -v root="$pid" '$1==root {n++} END {print n+0}')"
  descendants="$(count_descendants "$pid")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$epoch" "$pid" "$rss" "$threads" "$fds" "$sockets" \
    "$unix_sockets" "$direct_children" "$descendants" >>"$out"

  sleep "$interval"
done
