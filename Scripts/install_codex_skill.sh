#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
target="${CODEX_HOME:-$HOME/.codex}/skills/openconnect-native"
mkdir -p "$target/scripts"
install -m 644 "$root/skills/openconnect-native/SKILL.md" "$target/SKILL.md"
install -m 755 "$root/skills/openconnect-native/scripts/vpnctl.py" "$target/scripts/vpnctl.py"
install -m 644 "$root/skills/openconnect-native/scripts/service_access.py" "$target/scripts/service_access.py"
echo "Installed $target"
