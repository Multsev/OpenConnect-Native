#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
source version.env
mode=${1:-development}
team_id=${TEAM_ID:-HW5E2337TG}
build_root="$project_root/build"
app_path="$build_root/Release/CiscoConnect.app"
extension_path="$app_path/Contents/Library/SystemExtensions/CiscoTunnel.systemextension"
dmg_path="$build_root/CiscoConnect-${MARKETING_VERSION}.dmg"

./Scripts/generate_xcode_project.sh
rm -rf "$build_root"
if [[ "$mode" == "release" ]]; then
  signing_identity=${SIGNING_IDENTITY:-}
  [[ -n "$signing_identity" ]] || { echo "Release requires SIGNING_IDENTITY='Developer ID Application: …'." >&2; exit 1; }
  xcodebuild -project CiscoConnect.xcodeproj -scheme CiscoConnect -configuration Release -derivedDataPath "$build_root/DerivedData" DEVELOPMENT_TEAM="$team_id" build
else
  signing_identity="-"
  xcodebuild -project CiscoConnect.xcodeproj -scheme CiscoConnect -configuration Release -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO build
fi
mkdir -p "$(dirname "$app_path")"
cp -R "$build_root/DerivedData/Build/Products/Release/CiscoConnect.app" "$app_path"
./Scripts/prepare_openconnect_runtime.sh "$extension_path"
find "$extension_path/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --options runtime --sign "$signing_identity" {} \;
codesign --force --options runtime --sign "$signing_identity" --entitlements Extensions/CiscoTunnel/CiscoTunnel.entitlements "$extension_path"
codesign --force --options runtime --sign "$signing_identity" --entitlements App/CiscoConnect.entitlements "$app_path"
staging="$build_root/dmg-staging"
mkdir -p "$staging"
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "CiscoConnect" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
echo "Created $dmg_path"
[[ "$mode" != "release" ]] || echo "Notarize and staple this DMG before distribution."
