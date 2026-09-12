#!/bin/bash
# Compile the tagged development target without reload's app staging/installation.
set -euo pipefail
if [[ $# -ne 3 || ! "$3" =~ ^[a-z0-9]+([.][a-z0-9]+)*$ ]]; then
  echo "usage: check-native.sh <derived-data> <source-packages> <dotted-debug-tag>" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ ! -d GhosttyKit.xcframework ]]; then
  echo "error: warm the app first to prepare GhosttyKit.xcframework" >&2
  exit 1
fi
: "${DEVELOPER_DIR:?Glaeda must select the Xcode developer directory}"
BUNDLE_ID="com.cmuxterm.app.debug.$3"
source "$ROOT/scripts/native-compiler-options.sh"
cmux_native_compiler_options
exec "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$1" -clonedSourcePackagesDirPath "$2" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  'CMUX_CUA_HELPER_DISPLAY_NAME=cmux Computer Use' \
  CMUX_SIDEBAR_EXTENSION_POINT_ID="$BUNDLE_ID.cmux.sidebar" ${CMUX_NATIVE_XCODE_ARGS[@]+"${CMUX_NATIVE_XCODE_ARGS[@]}"} build -showBuildTimingSummary
