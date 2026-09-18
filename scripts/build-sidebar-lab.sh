#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="${1:?managed cache directory required}"
package="$root/Packages/macOS/CmuxSwiftRenderUI"
# No reload.sh: this loop never builds or terminates the cmux application.
/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$cache" --product reorder-lab --jobs 4
bin="$(/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$cache" --show-bin-path)"
app="$cache/Sidebar Lab.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/reorder-lab" "$app/Contents/MacOS/SidebarLab"
for bundle in "$bin"/*.bundle; do
  [[ -d "$bundle" ]] && /usr/bin/ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
# Historical snapshot copies are no longer bundled; the shared reader supplies data.
rm -f "$app/Contents/Resources/work.js"
if [[ "${CMUX_SIDEBAR_LAB_TESTS:-0}" == "1" ]]; then
  /usr/bin/xcrun swift test --package-path "$package" --scratch-path "$cache" --jobs 4
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.terminal-kit.sidebar-lab</string>
<key>CFBundleName</key><string>Sidebar Lab</string>
<key>CFBundleExecutable</key><string>SidebarLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
printf 'Sidebar lab built: %s\n' "$app"
