#!/bin/bash
set -euo pipefail

# Route and interface setup remains delegated to the upstream vpnc-script.
# DNS is deliberately withheld: its Darwin implementation mutates the active
# network service, which may be Wi-Fi or an unrelated VPN. CiscoConnectHelper
# installs scoped DNS directly on the OpenConnect utun interface instead.
script_directory=$(cd "$(dirname "$0")" && pwd)
upstream_script="$script_directory/vpnc-script.upstream"
[[ -x "$upstream_script" ]] || exit 78

INTERNAL_IP4_DNS="" "$upstream_script" "$@"
