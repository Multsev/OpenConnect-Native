#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || exit 77

target_root="/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime"
target_plist="/Library/LaunchDaemons/com.max.openconnectnative.helper.plist"

/bin/launchctl bootout system/com.max.openconnectnative.helper >/dev/null 2>&1 || true
/bin/rm -f "$target_plist"
/bin/rm -rf "$target_root"
