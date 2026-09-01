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

# Validate the individual JSON envelopes. Independent greps can accidentally
# match an id from one response and success data from another.
mapfile -t response_lines <<<"$response"
[[ ${#response_lines[@]} -eq 2 ]]
printf '%s\n' "${response_lines[@]}" | jq -s -e '
    length == 2
    and ([.[].id] | sort == [7, 8])
    and all(.[]; .ok == true and (.entries | type == "array"))
' >/dev/null

invalid="$(printf '%s\n' '{"id":9,"method":"trash","params":{"paths":[""]}}' | "$backend" --serve)"
jq -e '.id == 9 and .ok == false and (.error | type == "string")' <<<"$invalid" >/dev/null

malformed="$(printf '%s\n' '{"id":11,"method":42,"params":{}}' | "$backend" --serve)"
jq -e '.id == 11 and .ok == false and (.error | type == "string")' <<<"$malformed" >/dev/null

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
jq -e '.id == 10 and .ok == false and (.error | type == "string")' <<<"$descendant" >/dev/null
test ! -e "$test_dir/source/child/source"
