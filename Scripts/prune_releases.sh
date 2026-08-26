#!/usr/bin/env bash
set -euo pipefail

mode=${1:-local}
keep_count=${2:-2}
project_root=$(cd "$(dirname "$0")/.." && pwd)

[[ "$keep_count" =~ ^[1-9][0-9]*$ ]] || {
  echo "keep_count must be a positive integer." >&2
  exit 1
}

prune_local_releases() {
  local release_root=${RELEASE_ROOT:-"$project_root/Releases"}
  [[ -d "$release_root" ]] || return 0

  versions=()
  while IFS= read -r version; do
    versions+=("$version")
  done < <(
      find "$release_root" -maxdepth 1 -type f -name 'OpenConnect-Native-*.dmg' -print \
        | sed -E 's#^.*/OpenConnect-Native-([0-9]+\.[0-9]+\.[0-9]+)\.dmg$#\1#' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr
    )

  for ((index = keep_count; index < ${#versions[@]}; index++)); do
    version=${versions[$index]}
    rm -f \
      "$release_root/OpenConnect-Native-$version.dmg" \
      "$release_root/OpenConnect-Native-$version.dmg.sha256"
    echo "Removed local release $version"
  done
}

prune_github_releases() {
  command -v gh >/dev/null || {
    echo "GitHub CLI is required for GitHub release cleanup." >&2
    exit 1
  }

  tags=()
  while IFS= read -r tag; do
    tags+=("$tag")
  done < <(
      gh release list --limit 100 --json tagName,createdAt,isDraft \
        --jq "map(select(.isDraft == false)) | sort_by(.createdAt) | reverse | .[$keep_count:][] | .tagName"
    )

  for tag in "${tags[@]}"; do
    gh release delete "$tag" --yes
    echo "Removed GitHub release $tag (Git tag preserved)"
  done
}

case "$mode" in
  local) prune_local_releases ;;
  github) prune_github_releases ;;
  *)
    echo "Usage: $0 [local|github] [keep_count]" >&2
    exit 1
    ;;
esac
