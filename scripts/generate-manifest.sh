#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$project_dir/manifest.json}"
version="$("$project_dir/scripts/read-version.sh")"
template="$project_dir/manifest.json.in"

mkdir -p -- "$(dirname -- "$output")"
sed "s/@PROJECT_VERSION@/$version/g" "$template" > "$output"
