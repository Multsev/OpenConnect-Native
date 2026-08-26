#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
"$project_root/Scripts/package_app.sh"
open "$project_root/OpenConnect Native.app"
