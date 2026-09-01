#!/usr/bin/env bash
set -euo pipefail

backend="${1:?backend executable is required}"
response="$(
    {
        printf '%s' '{"id":7,"method":"li'
        printf '%s\n' 'st","params":{"path":"/","showHidden":false}}'
        printf '%s\n' '{"id":8,"method":"list","params":{"path":"/","showHidden":false}}'
    } | "$backend" --serve
)"

grep -q '"id":7' <<<"$response"
grep -q '"id":8' <<<"$response"
grep -q '"ok":true' <<<"$response"
grep -q '"entries":' <<<"$response"

invalid="$(printf '%s\n' '{"id":9,"method":"trash","params":{"paths":[""]}}' | "$backend" --serve)"
grep -q '"id":9' <<<"$invalid"
grep -q '"ok":false' <<<"$invalid"

test_dir="$(mktemp -d /tmp/filesail-backend-test.XXXXXX)"
cleanup() {
    if [[ -n "$test_dir" && -d "$test_dir" ]]; then
        rm -rf -- "$test_dir"
    fi
}
trap cleanup EXIT

mkdir -p -- "$test_dir/source/child"
descendant_request="$(printf '{"id":10,"method":"copy","params":{"paths":["%s/source"],"targetDirectory":"%s/source/child"}}\n' "$test_dir" "$test_dir")"
descendant="$(printf '%s\n' "$descendant_request" | "$backend" --serve)"
grep -q '"id":10' <<<"$descendant"
grep -q '"ok":false' <<<"$descendant"
test ! -e "$test_dir/source/child/source"
