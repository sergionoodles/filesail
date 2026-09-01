#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${FILESAIL_BUILD_DIR:-$project_dir/build}"

cmake -S "$project_dir" -B "$build_dir"
cmake --build "$build_dir" "$@"
