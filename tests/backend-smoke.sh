#!/usr/bin/env bash
set -euo pipefail

backend="${1:?backend executable is required}"
test_dir="$(mktemp -d /tmp/filesail-backend-test.XXXXXX)"
export XDG_CONFIG_HOME="$test_dir/config"
cleanup() {
    if [[ -n "$test_dir" && -d "$test_dir" ]]; then
        rm -rf -- "$test_dir"
    fi
}
trap cleanup EXIT
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

invalid_terminal="$(printf '%s\n' '{"id":20,"method":"terminal","params":{"path":""}}' | "$backend" --serve)"
jq -e '.id == 20 and .ok == false and (.error | type == "string")' <<<"$invalid_terminal" >/dev/null

# Preview providers are additive and reject unsafe paths without affecting the
# established filesystem protocol.
preview_capabilities="$(printf '%s\n' '{"id":28,"method":"previewCapabilities","params":{}}' | "$backend" --serve)"
jq -e '.id == 28 and .ok == true and (.flavors | index("normal"))' <<<"$preview_capabilities" >/dev/null
preview_relative="$(printf '%s\n' '{"id":29,"method":"textPreview","params":{"path":"relative.txt"}}' | "$backend" --serve)"
jq -e '.id == 29 and .ok == false and (.error | type == "string")' <<<"$preview_relative" >/dev/null

# Diagnostic logs belong on stderr. Mixing them into stdout would break the
# newline-delimited JSON protocol.
protocol_out="$(printf '%s\n' '{"id":31,"method":"previewCapabilities","params":{}}' | FILESAIL_LOG=info "$backend" --serve 2>"$test_dir/backend.log")"
jq -e '.id == 31 and .ok == true' <<<"$protocol_out" >/dev/null
grep -q '\[filesail:backend\]\[info\] serving' "$test_dir/backend.log"
if grep -q '\[filesail:' <<<"$protocol_out"; then
    printf 'backend logs leaked onto stdout\n' >&2
    exit 1
fi

mkdir -p -- "$test_dir/source/child"

# Locations are durable, atomic snapshots. Duplicate canonical adds and unknown
# removals are intentionally idempotent.
locations="$(printf '{"id":24,"method":"locations.list","params":{}}\n{"id":25,"method":"locations.add","params":{"collection":"projects","path":"%s"}}\n{"id":26,"method":"locations.add","params":{"collection":"projects","path":"%s"}}\n{"id":27,"method":"locations.remove","params":{"collection":"projects","id":"11111111-1111-4111-8111-111111111111"}}\n' "$test_dir" "$test_dir" | "$backend" --serve)"
jq -s -e '
    length == 4
    and all(.[]; .ok == true and (.locations.version == 1))
    and (.[0].locations.projects | length == 0)
    and (.[1].locations.projects | length == 1)
    and (.[2].locations.projects | length == 1)
    and (.[3].locations.projects | length == 1)
' <<<"$locations" >/dev/null

# Context is opt-in and is derived from safe direct entries regardless of the
# hidden-file display setting. Symlink markers must not count as evidence.
mkdir -p -- "$test_dir/.agents" "$test_dir/.github/instructions"
touch -- "$test_dir/AGENTS.md" "$test_dir/.git" "$test_dir/package.json" "$test_dir/example.cpp"
ln -s -- AGENTS.md "$test_dir/CLAUDE.md"
context_listing="$(printf '{"id":22,"method":"list","params":{"path":"%s","showHidden":false,"includeContext":true}}\n' "$test_dir" | "$backend" --serve)"
jq -e '
    .id == 22 and .ok == true
    and ([.context.signals[] | select(.id == "agent-instructions" and .category == "ai") | .evidence[]] | sort == [".agents", "AGENTS.md"])
    and ([.context.signals[] | select(.id == "git") | .evidence] == [[".git"]])
    and ([.context.signals[] | select(.id == "node") | .evidence] == [["package.json"]])
    and ([.context.signals[] | select(.id == "cpp") | .evidence[]] | index("example.cpp"))
    and ([.context.signals[] | select(.id == "claude")] | length == 0)
' <<<"$context_listing" >/dev/null
no_context_listing="$(printf '{"id":23,"method":"list","params":{"path":"%s"}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 23 and .ok == true and has("context") | not' <<<"$no_context_listing" >/dev/null
terminal_output="$test_dir/terminal-working-directory"
terminal_script="$test_dir/test-terminal"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$PWD" > "$FILESAIL_TERMINAL_OUTPUT"' > "$terminal_script"
chmod +x -- "$terminal_script"
terminal_response="$(env TERMINAL="$terminal_script" FILESAIL_TERMINAL_OUTPUT="$terminal_output" "$backend" --serve <<<"{\"id\":21,\"method\":\"terminal\",\"params\":{\"path\":\"$test_dir\"}}")"
jq -e '.id == 21 and .ok == true' <<<"$terminal_response" >/dev/null
for _ in {1..20}; do
    [[ -f "$terminal_output" ]] && break
    sleep 0.1
done
[[ $(<"$terminal_output") == "$test_dir" ]]

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
