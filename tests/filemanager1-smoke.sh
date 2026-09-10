#!/usr/bin/env bash
set -euo pipefail

service="${1:?FileManager1 executable is required}"
test_dir="$(mktemp -d /tmp/filesail-filemanager1-test.XXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT
dbus-run-session -- sh -eu -c '
    "$1" >"$2/service.log" 2>&1 &
    pid=$!
    trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
    # Check ownership without activating another installed file manager. A
    # fixed startup sleep can both flake and inspect the wrong service.
    ready=false
    for attempt in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            cat "$2/service.log" >&2
            exit 1
        fi
        owner=$(gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.GetConnectionUnixProcessID \
            org.freedesktop.FileManager1 2>/dev/null) || owner=""
        if [ "$owner" = "(uint32 $pid,)" ]; then
            ready=true
            break
        fi
        sleep 0.1
    done
    if [ "$ready" != true ]; then
        cat "$2/service.log" >&2
        printf "%s\n" "FileSail did not acquire its D-Bus name" >&2
        exit 1
    fi
    gdbus introspect --session --dest org.freedesktop.FileManager1 \
        --object-path /org/freedesktop/FileManager1 >"$2/introspection"
    grep -q "ShowFolders" "$2/introspection"
    grep -q "ShowItems" "$2/introspection"
    grep -q "ShowItemProperties" "$2/introspection"
' -- "$service" "$test_dir"
