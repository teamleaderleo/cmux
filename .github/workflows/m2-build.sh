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
  "${cache[@]}" >"$log" 2>&1 &
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
    kill -TERM $xb; sleep 20; pkill -9 -x xcodebuild; pkill -9 -f SWBBuildService; break
  fi
  if (( tick % 3 == 0 )); then
    fe=$(pgrep -x swift-frontend | wc -l | tr -d ' '); cl=$(pgrep -x clang | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$((now-start))" "$fe" "$cl" "$(sysctl -n vm.loadavg | awk '{print $2}')" \
      "$(wc -l <"$log" | tr -d ' ')" "$(tr -d '\n' <"$W/store/stats.json" 2>/dev/null)" >>"$samp"
  fi
done
wait $xb 2>/dev/null
end=$(date +%s)
cp "$W/store/stats.json" "$OUT/stats-$label-after.json" 2>/dev/null
if grep -q '\*\* BUILD SUCCEEDED' "$log"; then rc=ok; elif [[ $timedout == yes ]]; then rc=TIMEOUT; else rc=FAIL; fi
hits=$(grep -c 'cache hit' "$log"); misses=$(grep -c 'cache miss' "$log")
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mode" "$rc" "$((end-start))" "$hits" "$misses" "$stalled" \
  | tee -a "$OUT/summary.tsv"
grep -E 'error:|\*\* BUILD' "$log" | head -20
df -h "$W" | tail -1 | sed "s/^/[$label] disk after: /"
