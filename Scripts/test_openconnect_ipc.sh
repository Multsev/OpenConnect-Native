#!/usr/bin/env bash
set -euo pipefail

app_path=${1:?Usage: test_openconnect_ipc.sh /path/to/CiscoConnect.app}
helper="$app_path/Contents/Resources/OpenConnect/bin/CiscoConnectHelper"
installer="$app_path/Contents/Resources/InstallPrivilegedHelper.sh"
uninstaller="$app_path/Contents/Resources/UninstallPrivilegedHelper.sh"
daemon_plist="$app_path/Contents/Resources/com.max.openconnectnative.helper.plist"
[[ -x "$helper" ]] || { echo "CiscoConnectHelper was not built." >&2; exit 1; }
[[ -x "$installer" && -x "$uninstaller" ]] || { echo "Privileged helper lifecycle scripts are missing." >&2; exit 1; }
/usr/bin/otool -L "$helper" | /usr/bin/grep -Fq 'SystemConfiguration.framework' || {
  echo "Helper is missing SystemConfiguration runtime checks." >&2
  exit 1
}
/bin/bash -n "$installer" "$uninstaller"
/usr/bin/plutil -lint "$daemon_plist" >/dev/null
/usr/bin/grep -Fq '/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime' "$uninstaller"
/usr/bin/grep -Fq '/Library/LaunchDaemons/com.max.openconnectnative.helper.plist' "$uninstaller"

session_directory=$(mktemp -d /tmp/CiscoConnect-ipc-test.XXXXXX)
cleanup() { rm -r "$session_directory"; }
trap cleanup EXIT

request_path="$session_directory/request.plist"
status_path="$session_directory/status.plist"
otp_path="$session_directory/otp"
pid_path="$session_directory/pid"

plutil -create xml1 "$request_path"
plutil -insert mode -string discover "$request_path"
plutil -insert gateway -string invalid-url "$request_path"
plutil -insert statusPath -string "$status_path" "$request_path"
plutil -insert otpPath -string "$otp_path" "$request_path"
plutil -insert pidPath -string "$pid_path" "$request_path"
plutil -insert vpncScript -string /dev/null "$request_path"
chmod 600 "$request_path"

"$helper" "$request_path" >/dev/null 2>&1 || true

[[ ! -e "$request_path" ]] || { echo "Helper request was not deleted." >&2; exit 1; }
[[ -f "$status_path" ]] || { echo "Helper status was not created." >&2; exit 1; }
plutil -extract networkInfo xml1 -o /dev/null "$status_path"
[[ $(stat -f '%Lp' "$status_path") == 644 ]] || {
  echo "Helper status is not readable by the GUI." >&2
  exit 1
}

echo "OpenConnect IPC permissions verified."
