#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
source version.env
mode=${1:-development}
team_id=${TEAM_ID:-HW5E2337TG}
build_root="$project_root/build"
release_root="$project_root/Releases"
app_path="$build_root/Release/CiscoConnect.app"
dmg_path="$release_root/OpenConnect-Native-${MARKETING_VERSION}.dmg"

./Scripts/generate_app_icon.swift App/Resources/OpenConnectNative.icns App/Brand/OpenConnectNative-AppIcon.png
./Scripts/generate_xcode_project.sh
rm -rf "$build_root"
mkdir -p "$release_root"
rm -f "$dmg_path" "$dmg_path.sha256"
if [[ "$mode" == "release" ]]; then
  signing_identity=${SIGNING_IDENTITY:-}
  [[ -n "$signing_identity" ]] || { echo "Release requires SIGNING_IDENTITY='Developer ID Application: …'." >&2; exit 1; }
  codesign_arguments=(--force --options runtime --sign "$signing_identity")
  xcodebuild -project CiscoConnect.xcodeproj -scheme CiscoConnect -configuration Release -derivedDataPath "$build_root/DerivedData" DEVELOPMENT_TEAM="$team_id" build
else
  signing_identity="-"
  # Hardened Runtime library validation cannot be used with an ad-hoc signature:
  # embedded dylibs have no common Team ID. Developer ID releases use it above.
  codesign_arguments=(--force --sign "$signing_identity")
  xcodebuild -project CiscoConnect.xcodeproj -scheme CiscoConnect -configuration Release -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO build
fi
mkdir -p "$(dirname "$app_path")"
cp -R "$build_root/DerivedData/Build/Products/Release/CiscoConnect.app" "$app_path"
if [[ $(plutil -extract LSUIElement raw "$app_path/Contents/Info.plist" 2>/dev/null || echo false) == true ]]; then
  echo "Window mode must remain visible by default." >&2
  exit 1
fi
./Scripts/build_openconnect_helper.sh "$app_path"
./Scripts/test_openconnect_ipc.sh "$app_path"
./Scripts/prepare_openconnect_runtime.sh "$app_path"
find "$app_path/Contents/Frameworks" -type f -name '*.dylib' -exec codesign "${codesign_arguments[@]}" {} \;
codesign "${codesign_arguments[@]}" "$app_path/Contents/Resources/OpenConnect/bin/CiscoConnectHelper"
codesign "${codesign_arguments[@]}" --entitlements App/CiscoConnect.entitlements "$app_path"
staging="$build_root/dmg-staging"
mkdir -p "$staging"
cp -R "$app_path" "$staging/OpenConnect Native.app"
plutil -extract CFBundleExecutable raw "$staging/OpenConnect Native.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$staging/OpenConnect Native.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "OpenConnect Native" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
shasum -a 256 "$dmg_path" > "$dmg_path.sha256"

# Verify the final renamed bundle from the disk image, then discard all
# intermediate products. Releases remains the only user-facing output folder.
verify_mount=$(mktemp -d /tmp/OpenConnectNativeVerify.XXXXXX)
cleanup_verification() {
  hdiutil detach "$verify_mount" >/dev/null 2>&1 || true
  rmdir "$verify_mount" >/dev/null 2>&1 || true
}
trap cleanup_verification EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$verify_mount" "$dmg_path" >/dev/null
codesign --verify --deep --strict "$verify_mount/OpenConnect Native.app"
hdiutil detach "$verify_mount" >/dev/null
rmdir "$verify_mount"
trap - EXIT
rm -rf "$build_root"
./Scripts/prune_releases.sh local 2

echo "Created $dmg_path"
[[ "$mode" != "release" ]] || echo "Notarize and staple this DMG before distribution."
