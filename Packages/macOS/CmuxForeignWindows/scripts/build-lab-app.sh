#!/usr/bin/env bash
# Builds ForeignWindowLab and wraps it in a signed ForeignWindowLab.app under
# the package's .build directory. Only an app bundle can be the claude://
# handler, so this is how the lab exercises sign-in link routing.
#
# usage: scripts/build-lab-app.sh [--sign "<codesigning identity>"]
#
# Signs ad-hoc by default. Builds only; it never opens the app or registers it
# with Launch Services.
set -euo pipefail

usage() {
  echo "usage: $0 [--sign \"<codesigning identity>\"]" >&2
}

identity="-"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      identity="$2"
      shift 2
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

swift build -c debug --product ForeignWindowLab
bin_dir="$(swift build -c debug --show-bin-path)"
executable="$bin_dir/ForeignWindowLab"
resources="$bin_dir/CmuxForeignWindows_CmuxForeignWindows.bundle"
test -x "$executable"
test -d "$resources"

app="$package_dir/.build/ForeignWindowLab.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$executable" "$app/Contents/MacOS/ForeignWindowLab"
# Bundle.module looks in Bundle.main.resourceURL first.
cp -R "$resources" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ForeignWindowLab</string>
  <key>CFBundleIdentifier</key>
  <string>com.cmuxterm.foreignwindowlab</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Foreign Window Lab</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Foreign Window Lab forwards claude:// sign-in links to the Claude Desktop copy that started the sign-in.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.cmuxterm.foreignwindowlab.claude</string>
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
