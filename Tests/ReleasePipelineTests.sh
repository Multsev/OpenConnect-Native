#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d /tmp/OpenConnectReleaseTests.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

release_root="$test_root/Releases"
mkdir -p "$release_root"
for version in 0.4.9 0.5.1 0.5.2 0.5.3 0.10.0; do
  touch \
    "$release_root/OpenConnect-Native-$version.dmg" \
    "$release_root/OpenConnect-Native-$version.dmg.sha256"
done

RELEASE_ROOT="$release_root" "$project_root/Scripts/prune_releases.sh" local 2 >/dev/null

[[ -f "$release_root/OpenConnect-Native-0.10.0.dmg" ]]
[[ -f "$release_root/OpenConnect-Native-0.5.3.dmg" ]]
[[ ! -e "$release_root/OpenConnect-Native-0.5.2.dmg" ]]
[[ $(find "$release_root" -type f | wc -l | tr -d ' ') == 4 ]]

mock_bin="$test_root/bin"
delete_log="$test_root/deleted-tags"
mkdir -p "$mock_bin"
cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "release list")
    printf '%s\n' v0.5.1 v0.5.0
    ;;
  "release delete")
    printf '%s\n' "$3" >> "$GH_DELETE_LOG"
    ;;
  *)
    exit 2
    ;;
esac
MOCK_GH
chmod +x "$mock_bin/gh"

PATH="$mock_bin:$PATH" GH_DELETE_LOG="$delete_log" \
  "$project_root/Scripts/prune_releases.sh" github 2 >/dev/null

printf '%s\n' v0.5.1 v0.5.0 > "$test_root/expected-tags"
cmp "$test_root/expected-tags" "$delete_log"

echo "Release retention tests passed."
