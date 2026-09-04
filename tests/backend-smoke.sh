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

# Preview content limits are exact at the boundary. A terminal newline does
# not manufacture an extra empty line.
for line_count in 499 500 501; do
    seq "$line_count" > "$test_dir/lines-$line_count.txt"
    text_boundary="$(printf '{"id":%s,"method":"textPreview","params":{"path":"%s/lines-%s.txt"}}\n' "$line_count" "$test_dir" "$line_count" | "$backend" --serve)"
    jq -e --argjson count "$line_count" '
        .id == $count and .ok == true and .lineCount == (if $count > 500 then 500 else $count end)
        and .truncated == ($count > 500)
    ' <<<"$text_boundary" >/dev/null
done
for character_count in 65535 65536 65537; do
    head -c "$character_count" /dev/zero | tr '\0' 'a' > "$test_dir/chars-$character_count.txt"
    character_boundary="$(printf '{"id":%s,"method":"textPreview","params":{"path":"%s/chars-%s.txt"}}\n' "$character_count" "$test_dir" "$character_count" | "$backend" --serve)"
    jq -e --argjson count "$character_count" '.id == $count and .ok == true and .truncated == ($count > 65536)' <<<"$character_boundary" >/dev/null
done

# Thumbnail batches and directory completion have independent hard caps.
thumbnail_items="["
for _ in $(seq 1 65); do thumbnail_items+='{ "path": "relative" },'; done
thumbnail_items="${thumbnail_items%,}]"
thumbnail_boundary="$(printf '{"id":30,"method":"thumbnailBatch","params":{"items":%s}}\n' "$thumbnail_items" | "$backend" --serve)"
jq -e '.id == 30 and .ok == false and (.error | contains("64"))' <<<"$thumbnail_boundary" >/dev/null
mkdir -p -- "$test_dir/completion/apple" "$test_dir/completion/application" "$test_dir/completion/apricot"
completion="$(printf '{"id":32,"method":"completeDirectories","params":{"parent":"%s/completion","prefix":"ap"}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 32 and .ok == true and (.entries | length == 3) and ([.entries[].name] | sort == ["apple", "application", "apricot"])' <<<"$completion" >/dev/null

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
    map(select(.event? == null)) as $responses
    | ($responses | length == 4)
    and ($responses | all(.[]; .ok == true and (.locations.version == 1)))
    and ($responses[0].locations.projects | length == 0)
    and ($responses[1].locations.projects | length == 1)
    and ($responses[2].locations.projects | length == 1)
    and ($responses[3].locations.projects | length == 1)
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

# Mutation activity is reported as ordered backend events while the original
# request still receives its normal terminal response. The second copy stays
# queued behind the first because mutations are dispatched FIFO.
mkdir -p -- "$test_dir/action-source-a/nested" "$test_dir/action-source-b" "$test_dir/action-destination"
dd if=/dev/zero of="$test_dir/action-source-a/nested/payload" bs=1M count=8 status=none
printf 'queued copy' > "$test_dir/action-source-b/payload"
action_output="$({
    printf '{"id":60,"method":"copy","params":{"paths":["%s/action-source-a"],"targetDirectory":"%s/action-destination"}}\n' "$test_dir" "$test_dir"
    printf '{"id":61,"method":"copy","params":{"paths":["%s/action-source-b"],"targetDirectory":"%s/action-destination"}}\n' "$test_dir" "$test_dir"
    printf '%s\n' '{"id":62,"method":"operations.list","params":{}}'
} | "$backend" --serve)"
jq -s -e --arg source "$test_dir/action-source-a/nested/payload" '
    ([.[] | select(.event == "operationChanged" and .operation.id == 60)] | length >= 2)
    and ([.[] | select(.event == "operationChanged" and .operation.id == 60) | .operation.state] | index("queued") != null)
    and ([.[] | select(.event == "operationChanged" and .operation.id == 60) | .operation.state] as $states | ($states | index("queued")) < ($states | index("running")))
    and ([.[] | select(.event == "operationChanged" and .operation.id == 61) | .operation.state] | index("queued") != null)
    and ([.[] | select(.id == 62)][0] | .ok == true and (.operations | map(.id) == [60, 61]) and (.operations | map(.state) == ["running", "queued"]))
    and ([.[] | select(.event == "operationChanged" and .operation.id == 60 and .operation.progress.currentPath == $source)] | length > 0)
    and ([.[] | select(.event == "operationChanged" and .operation.id == 60 and (((.operation.progress.bytesDone // "0") | tonumber) > 0))] | length > 0)
    and ([.[] | select(.event == "operationChanged" and ((.operation.progress.currentPath // "") | contains("/proc/self/fd/")))] | length == 0)
    and ([.[] | select(.id == 60)] | length == 1 and .[0].ok == true)
    and ([.[] | select(.id == 61)] | length == 1 and .[0].ok == true)
    and (([.[] | select((.event == "operationChanged" and .operation.id == 60) or (.id == 60))] | .[-1] | has("id")) == true)
' <<<"$action_output" >/dev/null
[[ -f "$test_dir/action-destination/action-source-a/nested/payload" ]]
[[ -f "$test_dir/action-destination/action-source-b/payload" ]]

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

# Listings expose symbolic permissions, effective executable state, and
# creation metadata for the file info view.
printf 'script' > "$test_dir/info-target"
chmod 644 "$test_dir/info-target"
mkdir -- "$test_dir/info-dir"
chmod 755 "$test_dir/info-dir"
info_listing="$(printf '{"id":40,"method":"list","params":{"path":"%s","showHidden":true}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 40 and .ok == true and ([.entries[] | select(.name=="info-target")][0] | .permissions == "-rw-r--r--" and .isExecutable == false and (.created | type == "string"))' <<<"$info_listing" >/dev/null
jq -e '[.entries[] | select(.name=="info-dir")][0] | .permissions == "drwxr-xr-x"' <<<"$info_listing" >/dev/null

# The executable bit toggles owner/group/other together, mirroring `chmod a+x`.
exec_on="$(printf '{"id":41,"method":"setExecutable","params":{"path":"%s/info-target","executable":true}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 41 and .ok == true and .executable == true' <<<"$exec_on" >/dev/null
[[ $(stat -c '%a' "$test_dir/info-target") == 755 ]]
exec_off="$(printf '{"id":42,"method":"setExecutable","params":{"path":"%s/info-target","executable":false}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 42 and .ok == true and .executable == false' <<<"$exec_off" >/dev/null
[[ $(stat -c '%a' "$test_dir/info-target") == 644 ]]

# Directories are refused so a quick toggle cannot remove traversal rights.
exec_dir="$(printf '{"id":43,"method":"setExecutable","params":{"path":"%s/info-dir","executable":false}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 43 and .ok == false and (.error | type == "string")' <<<"$exec_dir" >/dev/null
[[ $(stat -c '%a' "$test_dir/info-dir") == 755 ]]
exec_missing="$(printf '{"id":44,"method":"setExecutable","params":{"path":"%s/no-such-file","executable":true}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 44 and .ok == false and (.error | type == "string")' <<<"$exec_missing" >/dev/null
exec_invalid="$(printf '{"id":45,"method":"setExecutable","params":{"path":"%s/info-target","executable":"yes"}}\n' "$test_dir" | "$backend" --serve)"
jq -e '.id == 45 and .ok == false and (.error | type == "string")' <<<"$exec_invalid" >/dev/null
exec_empty="$(printf '%s\n' '{"id":46,"method":"setExecutable","params":{"path":""}}' | "$backend" --serve)"
jq -e '.id == 46 and .ok == false and (.error | type == "string")' <<<"$exec_empty" >/dev/null

if command -v setfacl >/dev/null && command -v getfacl >/dev/null; then
    printf 'acl' > "$test_dir/acl-source"
    if setfacl -m u:65534:r-- "$test_dir/acl-source"; then
        mkdir -- "$test_dir/acl-destination"
        acl_copy="$(printf '{"id":19,"method":"copy","params":{"paths":["%s/acl-source"],"targetDirectory":"%s/acl-destination"}}\n' "$test_dir" "$test_dir" | "$backend" --serve)"
        jq -e '.id == 19 and .ok == true' <<<"$acl_copy" >/dev/null
        getfacl -cnp "$test_dir/acl-destination/acl-source" | grep -E -x 'user:65534:r--([[:space:]]+#effective:r--)?'
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
