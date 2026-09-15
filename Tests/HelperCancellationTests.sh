#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d /tmp/OpenConnectCancellationTests.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
openconnect_prefix=${OPENCONNECT_PREFIX:-$(brew --prefix openconnect)}
xcrun clang -fobjc-arc -mmacosx-version-min=14.0 \
  -I"$openconnect_prefix/include" -L"$openconnect_prefix/lib" \
  -framework Foundation -framework SystemConfiguration -lopenconnect \
  "$project_root/Tests/HelperCancellationTests.m" -o "$test_root/helper-tests"
"$test_root/helper-tests"
