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

ambiguous_url="$(printf '%s\n' '{"id":12,"method":"list","params":{"path":"file:///tmp?ignored"}}' | "$backend" --serve)"
jq -e '.id == 12 and .ok == false and (.error | type == "string")' <<<"$ambiguous_url" >/dev/null

ambiguous_watch_url="$(printf '%s\n' '{"id":18,"method":"watch","params":{"path":"file:///tmp?ignored"}}' | "$backend" --serve)"
jq -e '.id == 18 and .ok == false and (.error | type == "string")' <<<"$ambiguous_watch_url" >/dev/null

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

# POSIX permits arbitrary non-NUL filename bytes, but this JSON protocol uses
# Unicode. Unsafe names must never be exposed as a path that aliases another
# filesystem entry.
printf 'unsafe' > "$test_dir/"$'invalid-\xff'
unsafe_listing="$(printf '{"id":13,"method":"list","params":{"path":"%s","showHidden":true}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 13 and .ok == true and .unsafeEntryCount == 1 and ([.entries[].name] | index("invalid-�") | not)' <<<"$unsafe_listing" >/dev/null

large_dir="$test_dir/large"
mkdir -- "$large_dir"
for number in $(seq 1 5001); do
    : > "$large_dir/$number"
done
large_listing="$(printf '{"id":14,"method":"list","params":{"path":"%s"}}\n' "$large_dir" | "$backend" --serve)"
jq -e '.id == 14 and .ok == false and .requiresConfirmation == true and .entryCountAtLeast >= 5001' <<<"$large_listing" >/dev/null
confirmed_large_listing="$(printf '{"id":15,"method":"list","params":{"path":"%s","allowLargeDirectory":true}}\n' "$large_dir" | "$backend" --serve)"
jq -e '.id == 15 and .ok == true and (.entries | length == 5001)' <<<"$confirmed_large_listing" >/dev/null

printf 'private' > "$test_dir/private-source"
chmod 600 "$test_dir/private-source"
mkdir -- "$test_dir/private-destination"
private_copy="$(printf '{"id":16,"method":"copy","params":{"paths":["%s/private-source"],"targetDirectory":"%s/private-destination"}}\n' "$test_dir" "$test_dir" | "$backend" --serve)"
jq -e '.id == 16 and .ok == true' <<<"$private_copy" >/dev/null
[[ $(stat -c '%a' "$test_dir/private-destination/private-source") == 600 ]]

if command -v setfacl >/dev/null && command -v getfacl >/dev/null; then
    printf 'acl' > "$test_dir/acl-source"
    if setfacl -m u:65534:r-- "$test_dir/acl-source"; then
        mkdir -- "$test_dir/acl-destination"
        acl_copy="$(printf '{"id":19,"method":"copy","params":{"paths":["%s/acl-source"],"targetDirectory":"%s/acl-destination"}}\n' "$test_dir" "$test_dir" | "$backend" --serve)"
        jq -e '.id == 19 and .ok == true' <<<"$acl_copy" >/dev/null
        getfacl -cnp "$test_dir/acl-destination/acl-source" | rg -x 'user:65534:r--(\s+#effective:r--)?'
    fi
fi

# Exercise the pinned-source cross-device move path when tmpfs is available.
if [[ -d /dev/shm && $(stat -c '%d' "$test_dir") != $(stat -c '%d' /dev/shm) ]]; then
    move_target="$(mktemp -d /dev/shm/filesail-backend-move.XXXXXX)"
    printf 'move me' > "$test_dir/cross-device-source"
    cross_device_move="$(printf '{"id":17,"method":"move","params":{"paths":["%s/cross-device-source"],"targetDirectory":"%s"}}\n' "$test_dir" "$move_target" | "$backend" --serve)"
    jq -e '.id == 17 and .ok == true' <<<"$cross_device_move" >/dev/null
    [[ ! -e "$test_dir/cross-device-source" && -f "$move_target/cross-device-source" ]]
    rm -rf -- "$move_target"
fi
