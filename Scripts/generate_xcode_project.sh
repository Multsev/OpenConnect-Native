#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
xcodegen generate --spec "$project_root/project.yml" --project "$project_root"
echo "Generated $project_root/CiscoConnect.xcodeproj"
