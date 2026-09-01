#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${FILESAIL_BACKEND:-$project_dir/build/filesail-backend}"

if [[ ! -x "$backend" ]]; then
    printf 'FileSail backend not found at %s\nRun: cmake -S . -B build && cmake --build build\n' "$backend" >&2
    exit 1
fi

export FILESAIL_BACKEND="$backend"
requested_path="${FILESAIL_PATH:-$HOME}"
while (($#)); do
    case "$1" in
        --path)
            [[ $# -ge 2 ]] || { printf '%s\n' 'filesail: --path requires a directory' >&2; exit 2; }
            requested_path="$2"
            shift 2
            ;;
        --path=*) requested_path="${1#--path=}"; shift ;;
        --help|-h) printf '%s\n' 'Usage: filesail [--path PATH] [PATH]'; exit 0 ;;
        -*) printf 'filesail: unknown option: %s\\n' "$1" >&2; exit 2 ;;
        *) requested_path="$1"; shift ;;
    esac
done
export FILESAIL_PATH="$requested_path"
export QS_APP_ID="dev.filesail.FileSail"

exec qs --allow-duplicate -p "$project_dir"
