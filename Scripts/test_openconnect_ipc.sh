#!/usr/bin/env bash
set -euo pipefail

app_path=${1:?Usage: test_openconnect_ipc.sh /path/to/CiscoConnect.app}
helper="$app_path/Contents/Resources/OpenConnect/bin/CiscoConnectHelper"
vpnc_wrapper="$app_path/Contents/Resources/OpenConnect/vpnc-script"
vpnc_upstream="$app_path/Contents/Resources/OpenConnect/vpnc-script.upstream"
installer="$app_path/Contents/Resources/InstallPrivilegedHelper.sh"
uninstaller="$app_path/Contents/Resources/UninstallPrivilegedHelper.sh"
daemon_plist="$app_path/Contents/Resources/com.max.openconnectnative.helper.plist"
[[ -x "$helper" ]] || { echo "CiscoConnectHelper was not built." >&2; exit 1; }
[[ -x "$vpnc_wrapper" && -x "$vpnc_upstream" ]] || {
  echo "DNS-safe vpnc-script runtime is incomplete." >&2
  exit 1
}
[[ -x "$installer" && -x "$uninstaller" ]] || { echo "Privileged helper lifecycle scripts are missing." >&2; exit 1; }
/usr/bin/otool -L "$helper" | /usr/bin/grep -Fq 'SystemConfiguration.framework' || {
  echo "Helper is missing SystemConfiguration runtime checks." >&2
  exit 1
}
/usr/bin/nm -u "$helper" | /usr/bin/grep -Fq '_openconnect_get_auth_expiration' || {
  echo "Helper does not read the server session expiration." >&2
  exit 1
}
/usr/bin/nm -u "$helper" | /usr/bin/grep -Fq '_openconnect_get_idle_timeout' || {
  echo "Helper does not read the server idle timeout." >&2
  exit 1
}
/bin/bash -n "$installer" "$uninstaller"
/usr/bin/plutil -lint "$daemon_plist" >/dev/null
/usr/bin/grep -Fq '/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime' "$uninstaller"
/usr/bin/grep -Fq '/Library/LaunchDaemons/com.max.openconnectnative.helper.plist' "$uninstaller"
/usr/bin/grep -Fq 'INTERNAL_IP4_DNS="" "$upstream_script"' "$vpnc_wrapper"

# The wrapper must prevent upstream Darwin code from touching DNS belonging to
# Wi-Fi or another active VPN while preserving the rest of its environment.
wrapper_test_root=$(mktemp -d /tmp/OpenConnectVPNScriptTest.XXXXXX)
cp "$vpnc_wrapper" "$wrapper_test_root/vpnc-script"
cat > "$wrapper_test_root/vpnc-script.upstream" <<'MOCK_VPNC'
#!/bin/bash
[[ -z "${INTERNAL_IP4_DNS:-}" ]]
[[ "${CISCO_SPLIT_DNS:-}" == "corp.test,team.test" ]]
MOCK_VPNC
chmod 755 "$wrapper_test_root/vpnc-script" "$wrapper_test_root/vpnc-script.upstream"
reason=connect INTERNAL_IP4_DNS="10.0.0.53" CISCO_SPLIT_DNS="corp.test,team.test" \
  "$wrapper_test_root/vpnc-script"
rm -rf "$wrapper_test_root"

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
