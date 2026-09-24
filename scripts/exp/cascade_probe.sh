#!/usr/bin/env bash
# Measures how far one edit spreads through an incremental cmux build.
# cascade_probe.sh <derived-data> <source-packages> <out-dir> [extra build setting...]
set -uo pipefail
dd="$1"; pkgs="$2"; out="$3"; shift 3
mkdir -p "$out"
FOUNDATION=Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/CascadeProbe.swift
SETTINGSUI=Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/CascadeProbe.swift
APP=Sources/Sidebar/GPUSpinner.swift

build() { # <step name>
  local name="$1" started log="$out/$1.log"
  started=$(date +%s)
  # shellcheck disable=SC2016
  xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$dd" -clonedSourcePackagesDirPath "$pkgs" \
    -disableAutomaticPackageResolution -destination "platform=macOS" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
    COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$dd/../cas" \
    "$@" -showBuildTimingSummary build-for-testing > "$log" 2>&1
  local status=$? seconds=$(( $(date +%s) - started ))
  python3 - "$log" "$name" "$seconds" "$status" >> "$out/results.jsonl" <<'PY'
import collections, json, re, sys
log, name, seconds, status = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
counts = collections.Counter()
for line in open(log, errors="replace"):
    if line.startswith("SwiftCompile normal ") and " /" in line.split("(in target")[0]:
        m = re.search(r"\(in target '([^']+)'", line)
        if m: counts[m.group(1)] += 1
top = dict(counts.most_common(12))
print(json.dumps({"step": name, "seconds": seconds, "status": status,
                  "cmux": counts.get("cmux", 0), "cmuxTests": counts.get("cmuxTests", 0),
                  "total": sum(counts.values()), "targets": top}))
PY
  tail -1 "$out/results.jsonl"
}

# Probes exist before the cold build, so each later step is exactly one edit.
printf 'enum CascadeProbe {\n    static func value() -> Int { 1 }\n}\n' > "$FOUNDATION"
printf 'enum CascadeProbe {\n    static func value() -> Int { 1 }\n}\n' > "$SETTINGSUI"
printf '\nprivate func cascadeProbeApp() -> Int { 1 }\n' >> "$APP"

build 0-cold "$@"
build 1-noop "$@"
sed -i '' 's/-> Int { 1 }/-> Int { 2 }/' "$FOUNDATION"; build 2-foundation-body "$@"
printf 'public func cmuxCascadeProbePublic() -> Int { 1 }\n' >> "$FOUNDATION"; build 3-foundation-public-api "$@"
sed -i '' 's/-> Int { 1 }/-> Int { 2 }/' "$SETTINGSUI"; build 4-settingsui-body "$@"
sed -i '' 's/cascadeProbeApp() -> Int { 1 }/cascadeProbeApp() -> Int { 2 }/' "$APP"; build 5-app-body "$@"
printf 'func cascadeProbeAppInternal() -> Int { 1 }\n' >> "$APP"; build 6-app-internal-api "$@"
