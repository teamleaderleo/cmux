#!/bin/bash
# Throwaway: glaeda#1134 M2 gate. One measured full cmux app build.
# usage: m2-build.sh <label> <mode: off|socket|localcas> <timeout-minutes>
# env: SRC (cmux checkout), W (work dir, real path), OUT (log dir)
set -u
label=$1; mode=$2; limit=$(( $3 * 60 ))
dd="$W/dd-$label"; log="$OUT/log-$label.txt"; samp="$OUT/samples-$label.tsv"
rm -rf "$dd"
case $mode in
  off) cache=(COMPILATION_CACHE_ENABLE_CACHING=NO) ;;
  socket) cache=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$W/localcas-$label"
      COMPILATION_CACHE_ENABLE_PLUGIN=YES COMPILATION_CACHE_REMOTE_SERVICE_PATH="$W/fcas.sock") ;;
  localcas) cache=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$W/sharedcas") ;;
esac
if [[ $mode != off ]]; then
  cache+=(COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES
    SWIFT_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES
    SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES
    SWIFT_OTHER_PREFIX_MAPPINGS="$dd=/^derived" CLANG_OTHER_PREFIX_MAPPINGS="$dd=/^derived")
fi
snap() { # $1 = reason
  local d="$OUT/snap-$label-$1"; mkdir -p "$d"
  ps -Ao pid,ppid,pcpu,rss,etime,state,command >"$d/ps.txt" 2>&1
  sysctl -n vm.loadavg >"$d/load.txt"
  cp "$W/store/stats.json" "$d/" 2>/dev/null
  for n in xcodebuild SWBBuildService swift-frontend clang swift-driver fleet-cas; do
    for p in $(pgrep -x "$n" | head -3); do sample "$p" 5 -file "$d/sample-$n-$p.txt" >/dev/null 2>&1; done
  done
  tail -50 "$log" >"$d/log-tail.txt"
}
cp "$W/store/stats.json" "$OUT/stats-$label-before.json" 2>/dev/null
df -h "$W" | tail -1 | sed "s/^/[$label] disk before: /"
cd "$SRC" || exit 2
start=$(date +%s)
xcodebuild build -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$dd" \
  -clonedSourcePackagesDirPath "$W/spm" -disableAutomaticPackageResolution \
  -showBuildTimingSummary CODE_SIGNING_ALLOWED=NO CMUX_SKIP_ZIG_BUILD=1 \
  COMPILER_INDEX_STORE_ENABLE=NO \
  "${cache[@]}" 2>&1 | perl -MTime::HiRes=time -ne 'BEGIN{$|=1} printf "%.1f %s", time, $_' >"$log" &
xb=$!
last=0; lastchg=$start; stalled=no; timedout=no; tick=0
while kill -0 $xb 2>/dev/null; do
  sleep 10; now=$(date +%s); tick=$((tick+1))
  sz=$(stat -f %z "$log")
  if [[ $sz != "$last" ]]; then last=$sz; lastchg=$now; fi
  if (( now - lastchg > 600 )) && [[ $stalled == no ]]; then
    stalled="yes@$((now-start))s"; echo "[$label] no log output for 10 min, sampling"; snap stall
  fi
  if (( now - start > limit )); then
    timedout=yes; echo "[$label] timeout after $limit s, sampling and killing"; snap timeout
    pkill -TERM -x xcodebuild; sleep 20; pkill -9 -x xcodebuild; pkill -9 -f SWBBuildService; break
  fi
  if true; then
    cpu=$(ps -Ao pcpu= | awk '{s+=$1} END{printf "%d", s}')
    fe=$(pgrep -x swift-frontend | wc -l | tr -d ' '); cl=$(pgrep -x clang | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((now-start))" "$cpu" "$fe" "$cl" "$(sysctl -n vm.loadavg | awk '{print $2}')" \
      "$(wc -l <"$log" | tr -d ' ')" "$(tr -d '\n' <"$W/store/stats.json" 2>/dev/null)" >>"$samp"
  fi
done
wait $xb 2>/dev/null
end=$(date +%s)
cp "$W/store/stats.json" "$OUT/stats-$label-after.json" 2>/dev/null
if grep -q '\*\* BUILD SUCCEEDED' "$log"; then rc=ok; elif [[ $timedout == yes ]]; then rc=TIMEOUT; else rc=FAIL; fi
hits=$(grep -c 'cache hit' "$log"); misses=$(grep -c 'cache miss' "$log")
# quiet gaps: stretches of >=20 s with no build output (Tuist's socket stall shows as 30-50 s bursts)
gaps=$(awk '{t=$1+0; if (p && t-p>=20) {n++; g+=t-p; if (t-p>m) m=t-p} p=t} END{printf "%d/%ds/max%ds", n, g, m}' "$log")
# idle samples: 10 s samples where all processes together used under 50% CPU (of 300%)
idle=$(awk -F'\t' '$2<50{n++} END{printf "%ds", n*10}' "$samp" 2>/dev/null)
awk '{t=$1+0; if (p && t-p>=20) printf "%.0fs gap before: %s\n", t-p, substr($0,1,200); p=t}' "$log" >"$OUT/gaps-$label.txt"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mode" "$rc" "$((end-start))" "$hits" "$misses" "$gaps" "$idle" "$stalled" \
  | tee -a "$OUT/summary.tsv"
grep -E 'error:|\*\* BUILD' "$log" | head -20
df -h "$W" | tail -1 | sed "s/^/[$label] disk after: /"
