#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$project_dir/build/filesail-backend"
plugin_dir="${NOCTALIA_CONFIG_DIR:-$HOME/.config/noctalia}/plugins/filesail"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"

if [[ ! -x "$backend" ]]; then
    printf 'FileSail backend not found at %s\nRun: cmake -S . -B build && cmake --build build\n' "$backend" >&2
    exit 1
fi

"$project_dir/scripts/generate-manifest.sh" "$project_dir/manifest.json"

if [[ -e "$plugin_dir" && ! -L "$plugin_dir" ]]; then
    printf 'Refusing to replace existing non-symlink plugin directory: %s\n' "$plugin_dir" >&2
    exit 1
fi

mkdir -p -- "$(dirname -- "$plugin_dir")" "$bin_dir"
ln -sfn -- "$project_dir" "$plugin_dir"
install -Dm755 -- "$backend" "$bin_dir/filesail-backend"

printf 'Installed Noctalia plugin link: %s -> %s\n' "$plugin_dir" "$project_dir"
printf 'Installed backend: %s/filesail-backend\n' "$bin_dir"
printf 'Enable FileSail in Noctalia Settings > Plugins, then add it to the bar.\n'
