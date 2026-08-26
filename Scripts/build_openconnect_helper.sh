#!/usr/bin/env bash
set -euo pipefail

app_path=${1:?"Pass CiscoConnect.app path."}
openconnect_prefix=${OPENCONNECT_PREFIX:-$(brew --prefix openconnect)}
destination="$app_path/Contents/Resources/OpenConnect/bin/CiscoConnectHelper"
mkdir -p "$(dirname "$destination")"
xcrun clang -fobjc-arc -mmacosx-version-min=14.0 \
  -I"$openconnect_prefix/include" -L"$openconnect_prefix/lib" \
  -framework Foundation -framework SystemConfiguration -lopenconnect \
  Helper/OpenConnectHelper.m -o "$destination"
chmod 755 "$destination"
