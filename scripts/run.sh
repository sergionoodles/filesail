#!/usr/bin/env bash
set -euo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
project_dir="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"
backend="${FILESAIL_BACKEND:-$project_dir/build/filesail-backend}"
clipboard="${FILESAIL_CLIPBOARD:-$project_dir/build/filesail-clipboard}"

if [[ ! -x "$backend" ]]; then
    printf 'FileSail backend not found at %s\nRun: cmake -S . -B build && cmake --build build\n' "$backend" >&2
    exit 1
fi

export FILESAIL_BACKEND="$backend"
export FILESAIL_CLIPBOARD="$clipboard"
# Development launches intentionally make transfer progress observable. The
# installed launcher does not set this hook, and developers can restore native
# speed with FILESAIL_DEV_TRANSFER_DELAY_MS=0.
export FILESAIL_DEV_TRANSFER_DELAY_MS="${FILESAIL_DEV_TRANSFER_DELAY_MS:-15}"
requested_path="${FILESAIL_PATH:-$HOME}"
selection_json="${FILESAIL_SELECTION_JSON:-[]}";
force_new_instance=false
ensure_window=false
while (($#)); do
    case "$1" in
        --path)
            [[ $# -ge 2 ]] || { printf '%s\n' 'filesail: --path requires a directory' >&2; exit 2; }
            requested_path="$2"
            shift 2
            ;;
        --path=*) requested_path="${1#--path=}"; shift ;;
        --select-json)
            [[ $# -ge 2 ]] || { printf '%s\n' 'filesail: --select-json requires JSON' >&2; exit 2; }
            selection_json="$2"
            shift 2
            ;;
        --help|-h) printf '%s\n' 'Usage: filesail [--path PATH] [PATH]' 'Options: --new-instance (temporary duplicate-host escape hatch)' 'Environment: FILESAIL_LOG=error|warn|info|debug (default: info)' 'Development transfer delay: FILESAIL_DEV_TRANSFER_DELAY_MS (default: 15; use 0 for native speed)'; exit 0 ;;
        --new-instance|--allow-duplicate) force_new_instance=true; shift ;;
        --ensure-window) ensure_window=true; shift ;;
        -*) printf 'filesail: unknown option: %s\\n' "$1" >&2; exit 2 ;;
        *) requested_path="$1"; shift ;;
    esac
done
if [[ -z "$requested_path" ]]; then requested_path="$HOME"; fi
if [[ ${#requested_path} -gt 4096 || "$requested_path" != /* || "$requested_path" == *://* || "$requested_path" == file:* ]]; then
    printf '%s\n' 'filesail: PATH must be an absolute local directory path' >&2
    exit 2
fi
export FILESAIL_SELECTION_JSON="$selection_json"
export FILESAIL_PATH="$requested_path"
export QS_APP_ID="dev.filesail.FileSail"

# Quickshell hides console.info/log at its default warning level. Enable QML
# info (and debug when requested) so FileSail's Logger reaches the console.
if [[ "$force_new_instance" == true ]]; then
    qs_args=(-p "$project_dir")
    case "${FILESAIL_LOG:-info}" in
        debug) qs_args+=(--log-rules "qml.debug=true;qml.info=true") ;;
        info) qs_args+=(--log-rules "qml.info=true") ;;
    esac
    exec qs "${qs_args[@]}"
fi

runtime_dir="${XDG_RUNTIME_DIR:-}"
if [[ -z "$runtime_dir" ]]; then
    runtime_dir="${TMPDIR:-/tmp}/filesail-runtime-${UID}"
    mkdir -m 700 -- "$runtime_dir" 2>/dev/null || true
    if [[ -L "$runtime_dir" || ! -d "$runtime_dir" || ! -O "$runtime_dir" \
        || $(stat -c '%a' -- "$runtime_dir") != 700 ]]; then
        printf 'filesail: unsafe runtime directory: %s\n' "$runtime_dir" >&2
        exit 1
    fi
fi
activation_lock="$runtime_dir/filesail-${UID}.lock"
exec {activation_lock_fd}>"$activation_lock"
flock -x "$activation_lock_fd"

ipc_call() {
    qs ipc --path "$project_dir" call filesail.v1 "$@"
}

if ipc_call ping 1 >/dev/null 2>&1; then
    activation_method=show
    activation_args=("$requested_path" "$selection_json" 1)
    if [[ "$ensure_window" == true ]]; then activation_method=ensure; activation_args=("$requested_path" 1); fi
    if ! ipc_call "$activation_method" "${activation_args[@]}" >/dev/null 2>&1; then
        printf '%s\n' 'filesail: existing host rejected the activation request' >&2
        exit 1
    fi
    exit 0
fi

qs_args=(--no-duplicate -p "$project_dir")
case "${FILESAIL_LOG:-info}" in
    debug) qs_args+=(--log-rules "qml.debug=true;qml.info=true") ;;
    info) qs_args+=(--log-rules "qml.info=true") ;;
esac

qs "${qs_args[@]}" >"$runtime_dir/filesail-qs.log" 2>&1 {activation_lock_fd}>&- &
host_pid=$!

# The first launcher supplied the host's initial path. If no-duplicate says
# another owner won, route this request to that owner.
for _ in {1..40}; do
    if ipc_call ping 1 >/dev/null 2>&1; then
        if kill -0 "$host_pid" 2>/dev/null; then exit 0; fi
        activation_method=show
        activation_args=("$requested_path" "$selection_json" 1)
        if [[ "$ensure_window" == true ]]; then activation_method=ensure; activation_args=("$requested_path" 1); fi
        if ipc_call "$activation_method" "${activation_args[@]}" >/dev/null 2>&1; then exit 0; fi
        break
    fi
    if ! kill -0 "$host_pid" 2>/dev/null; then break; fi
    sleep 0.05
done
if kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
fi
printf '%s\n' 'filesail: host did not publish its activation endpoint' >&2
exit 1
