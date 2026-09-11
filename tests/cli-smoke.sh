#!/usr/bin/env bash
set -euo pipefail

cli="${1:?filesail-cli executable is required}"
test_dir="$(mktemp -d /tmp/filesail-cli-test.XXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -- "$test_dir/bin"

cat > "$test_dir/bin/qs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == list ]]; then
    printf '%s\n' '[{"id":"test-instance","pid":123}]'
    exit 0
fi
if [[ "$1" == ipc && "$5" == filesail.control.v1 && "$6" == describe ]]; then
    printf '%s\n' '{"ok":true,"protocol":"filesail.control.v1","hostGeneration":"host-test","hostKind":"standalone","canCreateWindow":true,"windows":[{"window":"window-test","hostKind":"standalone","path":"/tmp","ready":true,"visible":true,"revision":7}]}'
    exit 0
fi
if [[ "$1" == ipc && "$5" == filesail.control.v1 && "$6" == submit ]]; then
    request="$7"
    printf '%s\n' "$request" | jq -e '.window == "window-test" and .method == "state" and .version == 1' >/dev/null
    printf '%s\n' '{"ok":true,"status":"succeeded","requestId":"test","window":"window-test","data":{"state":{"path":"/tmp"}}}'
    exit 0
fi
exit 1
EOF
chmod +x -- "$test_dir/bin/qs"

export FILESAIL_QS="$test_dir/bin/qs"
windows="$($cli windows list)"
jq -e '.ok == true and .windows[0].window == "window-test" and .windows[0].instanceId == "test-instance"' <<<"$windows" >/dev/null
state="$($cli --request-id test state)"
jq -e '.ok == true and .data.state.path == "/tmp"' <<<"$state" >/dev/null

# Arguments containing shell syntax stay one QProcess argument. The fake
# transport parses JSON and no marker file can be created by interpolation.
marker="$test_dir/should-not-exist"
if "$cli" navigate --location "\$(touch $marker)" >/dev/null 2>&1; then
    printf '%s\n' 'invalid fake navigation unexpectedly succeeded' >&2
    exit 1
fi
[[ ! -e "$marker" ]]
