#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
source version.env

swift build -c release

app_path="$project_root/CiscoConnect.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp .build/release/CiscoConnect "$app_path/Contents/MacOS/CiscoConnect"

cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CiscoConnect</string>
  <key>CFBundleDisplayName</key><string>CiscoConnect</string>
  <key>CFBundleIdentifier</key><string>com.max.ciscoconnect</string>
  <key>CFBundleExecutable</key><string>CiscoConnect</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

codesign --force --sign - "$app_path"
echo "Created $app_path"
