#!/usr/bin/env bash
set -euo pipefail

service="${1:?FileManager1 executable is required}"
dbus-run-session -- sh -c '
    "$1" >/tmp/filesail-filemanager1-smoke.log 2>&1 &
    pid=$!
    trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
    sleep 0.2
    gdbus introspect --session --dest org.freedesktop.FileManager1 \
        --object-path /org/freedesktop/FileManager1 >/tmp/filesail-filemanager1-introspection
    grep -q "ShowFolders" /tmp/filesail-filemanager1-introspection
    grep -q "ShowItems" /tmp/filesail-filemanager1-introspection
    grep -q "ShowItemProperties" /tmp/filesail-filemanager1-introspection
    exit 0
' -- "$service"
