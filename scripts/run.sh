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
        --help|-h) printf '%s\n' 'Usage: filesail [--path PATH] [PATH]' 'Environment: FILESAIL_LOG=error|warn|info|debug (default: info)'; exit 0 ;;
        -*) printf 'filesail: unknown option: %s\\n' "$1" >&2; exit 2 ;;
        *) requested_path="$1"; shift ;;
    esac
done
export FILESAIL_PATH="$requested_path"
export QS_APP_ID="dev.filesail.FileSail"

# Quickshell hides console.info/log at its default warning level. Enable QML
# info (and debug when requested) so FileSail's Logger reaches the console.
qs_args=(--allow-duplicate -p "$project_dir")
case "${FILESAIL_LOG:-info}" in
    debug) qs_args+=(--log-rules "qml.debug=true;qml.info=true") ;;
    info) qs_args+=(--log-rules "qml.info=true") ;;
esac

exec qs "${qs_args[@]}"
