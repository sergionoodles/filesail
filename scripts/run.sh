#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${FILESAIL_BACKEND:-$project_dir/build/filesail-backend}"

if [[ ! -x "$backend" ]]; then
    printf 'FileSail backend not found at %s\nRun: cmake -S . -B build && cmake --build build\n' "$backend" >&2
    exit 1
fi

export FILESAIL_BACKEND="$backend"
export FILESAIL_PATH="${1:-${FILESAIL_PATH:-$HOME}}"
export QS_APP_ID="dev.filesail.FileSail"

exec qs --allow-duplicate -p "$project_dir"
