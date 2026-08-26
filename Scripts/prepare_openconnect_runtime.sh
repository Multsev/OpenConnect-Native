#!/usr/bin/env bash
set -euo pipefail

# Creates a self-contained OpenConnect runtime inside the unsigned/ad-hoc app.
# This intentionally uses the developer's local Homebrew installation; a public
# release must be rebuilt for each supported architecture.
app_path=${1:?"Pass the built CiscoConnect.app path."}
homebrew_prefix=${HOMEBREW_PREFIX:-$(brew --prefix)}
openconnect_prefix=${OPENCONNECT_PREFIX:-$(brew --prefix openconnect)}
vpnc_script=${VPNC_SCRIPT:-"$homebrew_prefix/etc/vpnc/vpnc-script"}
license_file=${OPENCONNECT_LICENSE:-"$openconnect_prefix/COPYING.LGPL"}
[[ -x "$vpnc_script" ]] || { echo "vpnc-script not found: $vpnc_script" >&2; exit 1; }

runtime="$app_path/Contents/Resources/OpenConnect"
binary_dir="$runtime/bin"
frameworks="$app_path/Contents/Frameworks"
mkdir -p "$binary_dir" "$frameworks"
[[ -x "$binary_dir/CiscoConnectHelper" ]] || { echo "CiscoConnectHelper was not built." >&2; exit 1; }
cp -fL "$vpnc_script" "$runtime/vpnc-script"
chmod 755 "$binary_dir/CiscoConnectHelper" "$runtime/vpnc-script"
[[ ! -f "$license_file" ]] || cp -fL "$license_file" "$runtime/OpenConnect-LGPL-2.1.txt"

queue=()
queue_library() {
  local library=$1
  [[ "$library" == "$homebrew_prefix"/* && -f "$library" ]] || return 0
  local known
  for known in "${queue[@]:-}"; do [[ "$known" != "$library" ]] || return 0; done
  queue+=("$library")
}

while IFS= read -r dependency; do queue_library "$dependency"; done < <(otool -L "$binary_dir/CiscoConnectHelper" | tail -n +2 | awk '{print $1}')
for ((index = 0; index < ${#queue[@]}; index += 1)); do
  source_library=${queue[$index]}
  cp -fL "$source_library" "$frameworks/$(basename "$source_library")"
  while IFS= read -r dependency; do queue_library "$dependency"; done < <(otool -L "$source_library" | tail -n +2 | awk '{print $1}')
done

install_name_tool -add_rpath '@executable_path/../../../Frameworks' "$binary_dir/CiscoConnectHelper" 2>/dev/null || true
for binary in "$binary_dir/CiscoConnectHelper" "$frameworks"/*.dylib; do
  [[ -f "$binary" ]] || continue
  while IFS= read -r dependency; do
    [[ "$dependency" == "$homebrew_prefix"/* ]] || continue
    install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  [[ "$binary" != *.dylib ]] || install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
done
echo "Embedded libopenconnect helper plus ${#queue[@]} runtime libraries."
