#!/usr/bin/env bash
set -euo pipefail

directory=${1:?directory is required}
query=${2-}
page=${3:-1}
page_size=${4:-30}

if [[ ! -d "$directory" || ! -r "$directory" ]]; then
    printf 'Cannot read directory: %s\n' "$directory" >&2
    exit 1
fi
if [[ ! "$page" =~ ^[1-9][0-9]*$ || ! "$page_size" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Page and page size must be positive integers\n' >&2
    exit 2
fi

mapfile -d '' records < <(
    find "$directory" -mindepth 1 -maxdepth 1 -printf '%y\t%f\0' | sort -z -f
)

needle=${query,,}
first=$(( (page - 1) * page_size + 1 ))
last=$(( first + page_size - 1 ))
total=0
selected=()

for record in "${records[@]}"; do
    name=${record:2}
    if [[ -n "$needle" && ${name,,} != *"$needle"* ]]; then
        continue
    fi
    total=$(( total + 1 ))
    if (( total >= first && total <= last )); then
        selected+=("$record")
    fi
done

printf '%s\0' "$total"
if (( ${#selected[@]} > 0 )); then
    printf '%s\0' "${selected[@]}"
fi
