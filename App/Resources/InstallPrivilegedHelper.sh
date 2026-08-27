#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || exit 77
app_path=${1:?Application path is required}
version=${2:?Build version is required}
target_root="/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime"
target_plist="/Library/LaunchDaemons/com.max.openconnectnative.helper.plist"
temporary_root="/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime.new"
staged_app="/Library/PrivilegedHelperTools/com.max.openconnectnative.install-source.app"

cleanup() {
  /bin/rm -rf "$staged_app" "$temporary_root"
}
trap cleanup EXIT

# Work only with a root-owned snapshot. Verifying the original and copying it
# later would leave a time-of-check/time-of-use window in a user-writable app.
/bin/rm -rf "$staged_app" "$temporary_root"
/usr/bin/ditto --noqtn "$app_path" "$staged_app"
/usr/sbin/chown -R root:wheel "$staged_app"
/bin/chmod -R go-w "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

source_contents="$staged_app/Contents"
source_helper="$source_contents/Resources/OpenConnect/bin/CiscoConnectHelper"
source_runtime="$source_contents/Resources/OpenConnect"
source_frameworks="$source_contents/Frameworks"
source_plist="$source_contents/Resources/com.max.openconnectnative.helper.plist"

[[ -x "$source_helper" && -x "$source_runtime/vpnc-script" && -f "$source_plist" ]] || exit 78

/bin/launchctl bootout system/com.max.openconnectnative.helper >/dev/null 2>&1 || true
/bin/mkdir -p "$temporary_root/Contents/Resources" "$temporary_root/Contents/Frameworks"
/bin/cp -R "$source_runtime" "$temporary_root/Contents/Resources/OpenConnect"
/bin/cp -R "$source_frameworks/." "$temporary_root/Contents/Frameworks/"

# The exact designated requirement prevents another local process from using
# this root service even though the public build has only an ad-hoc signature.
/usr/bin/codesign -d -r- "$staged_app" 2>&1 \
  | /usr/bin/sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
  > "$temporary_root/client-requirement.txt"
[[ -s "$temporary_root/client-requirement.txt" ]] || exit 79
/bin/echo "$version" > "$temporary_root/version"

/usr/sbin/chown -R root:wheel "$temporary_root"
/bin/chmod -R go-w "$temporary_root"
/bin/chmod 755 "$temporary_root/Contents/Resources/OpenConnect/bin/CiscoConnectHelper"
/bin/chmod 755 "$temporary_root/Contents/Resources/OpenConnect/vpnc-script"

/bin/rm -rf "$target_root"
/bin/mv "$temporary_root" "$target_root"
/bin/cp "$source_plist" "$target_plist"
/usr/sbin/chown root:wheel "$target_plist"
/bin/chmod 644 "$target_plist"

# launchd can briefly retain the previous Mach service after bootout. Wait for
# that stale registration to disappear; otherwise a successful `print` can be
# mistaken for a successfully bootstrapped replacement.
for attempt in 1 2 3 4 5; do
  if ! /bin/launchctl print system/com.max.openconnectnative.helper >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 1
done

# Bootstrap the replacement and verify that launchd really registered it.
service_started=false
for attempt in 1 2 3 4 5; do
  /bin/launchctl bootstrap system "$target_plist" >/dev/null 2>&1 || true
  if /bin/launchctl print system/com.max.openconnectnative.helper >/dev/null 2>&1; then
    service_started=true
    break
  fi
  /bin/sleep 1
done
[[ "$service_started" == true ]] || exit 80
/bin/launchctl enable system/com.max.openconnectnative.helper
