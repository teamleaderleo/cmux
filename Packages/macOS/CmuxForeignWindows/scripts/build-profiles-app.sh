#!/usr/bin/env bash
# Builds ClaudeProfiles and wraps it in a signed "Claude Profiles.app" under
# the package's .build directory: a menu-bar launcher for one Claude Desktop
# instance per profile that also routes claude:// sign-in links while those
# instances run.
#
# usage: scripts/build-profiles-app.sh [--sign "<codesigning identity>"] [--install]
#
# --install quits a running copy and replaces ~/Applications/Claude Profiles.app.
# Neither mode opens the app or changes the claude:// handler; the app claims
# the handler itself only while profile instances run.
set -euo pipefail

usage() {
  echo "usage: $0 [--sign \"<codesigning identity>\"] [--install]" >&2
}

identity="SmolRunner Local Release Signing"
install=0
bundle_id="com.cmuxterm.claudeprofiles"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      identity="$2"
      shift 2
      ;;
    --install)
      install=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

swift build -c release --product ClaudeProfiles
bin_dir="$(swift build -c release --show-bin-path)"
executable="$bin_dir/ClaudeProfiles"
resources="$bin_dir/CmuxForeignWindows_CmuxForeignWindows.bundle"
test -x "$executable"
test -d "$resources"

app="$package_dir/.build/Claude Profiles.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$executable" "$app/Contents/MacOS/ClaudeProfiles"
# Bundle.module looks in Bundle.main.resourceURL first.
cp -R "$resources" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ClaudeProfiles</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Claude Profiles</string>
  <key>CFBundleDisplayName</key>
  <string>Claude Profiles</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Claude Profiles forwards claude:// sign-in links to the Claude Desktop copy that started the sign-in.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$bundle_id.claude</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>claude</string>
      </array>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$app/Contents/PkgInfo"

codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --strict "$app"

if [ "$identity" = "-" ]; then
  echo "Signed ad-hoc: $app"
else
  echo "Signed with \"$identity\": $app"
fi

if [ "$install" -eq 1 ]; then
  destination="$HOME/Applications/Claude Profiles.app"
  running_executable="$destination/Contents/MacOS/ClaudeProfiles"
  if pgrep -f "$running_executable" >/dev/null; then
    # A polite quit hands claude:// back to Claude.app before exiting.
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      pgrep -f "$running_executable" >/dev/null || break
      sleep 0.25
    done
    if pgrep -f "$running_executable" >/dev/null; then
      echo "Claude Profiles is still running; quit it and run --install again." >&2
      exit 1
    fi
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$destination"
  ditto "$app" "$destination"
  codesign --verify --strict "$destination"
  echo "Installed: $destination"
  echo "Open it with: open \"$destination\""
fi
