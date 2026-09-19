#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$root" --product AppleChatApp

bin_dir="$(swift build --package-path "$root" --show-bin-path)"
app_dir="$root/.build/AppleChatApp.app"
contents="$app_dir/Contents"

rm -rf "$app_dir"
mkdir -p "$contents/MacOS"
cp "$bin_dir/AppleChatApp" "$contents/MacOS/AppleChatApp"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AppleChatApp</string>
    <key>CFBundleIdentifier</key>
    <string>org.swiftagent.examples.AppleChatApp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SwiftAgent Apple Chat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if (($#)); then
    open -n "$app_dir" --args "$@"
else
    open -n "$app_dir"
fi
