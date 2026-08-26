#!/usr/bin/env bash
set -euo pipefail

extension_path=${1:?"Pass the built CiscoTunnel.systemextension path."}
frameworks="$extension_path/Contents/Frameworks"
openconnect_library=${OPENCONNECT_LIBRARY:-/opt/homebrew/opt/openconnect/lib/libopenconnect.5.dylib}
[[ -f "$openconnect_library" ]] || { echo "OpenConnect library not found: $openconnect_library" >&2; exit 1; }

mkdir -p "$frameworks"
chmod -R u+w "$extension_path"
queue=()
queue_library() {
  local library=$1
  [[ "$library" == /opt/homebrew/* && -f "$library" ]] || return 0
  local known
  for known in "${queue[@]:-}"; do [[ "$known" != "$library" ]] || return 0; done
  queue+=("$library")
}

queue_library "$openconnect_library"
for ((index = 0; index < ${#queue[@]}; index += 1)); do
  source_library=${queue[$index]}
  cp -fL "$source_library" "$frameworks/$(basename "$source_library")"
  while IFS= read -r dependency; do queue_library "$dependency"; done < <(otool -L "$source_library" | tail -n +2 | awk '{print $1}')
done

for binary in "$frameworks"/*.dylib "$extension_path/Contents/MacOS/CiscoTunnel"; do
  [[ -f "$binary" ]] || continue
  while IFS= read -r dependency; do
    [[ "$dependency" == /opt/homebrew/* ]] || continue
    install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  [[ "$binary" != *.dylib ]] || install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
done
echo "Embedded ${#queue[@]} OpenConnect runtime libraries."
