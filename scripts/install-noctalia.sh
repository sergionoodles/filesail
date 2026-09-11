#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$project_dir/build/filesail-backend"
cli="$project_dir/build/filesail-cli"
noctalia_data_home="${NOCTALIA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
plugin_dir="${noctalia_data_home%/}/noctalia/plugins/filesail"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"

if [[ ! -x "$backend" || ! -x "$cli" ]]; then
    printf 'FileSail native tools not found in %s/build\nRun: cmake -S . -B build && cmake --build build\n' "$project_dir" >&2
    exit 1
fi

"$project_dir/scripts/generate-noctalia-plugin.sh"

if [[ -e "$plugin_dir" && ! -L "$plugin_dir" ]]; then
    printf 'Refusing to replace existing non-symlink plugin directory: %s\n' "$plugin_dir" >&2
    exit 1
fi
if [[ ( -e "$bin_dir/filesail" || -L "$bin_dir/filesail" ) && ! -x "$bin_dir/filesail" ]]; then
    printf 'Refusing to replace non-executable launcher: %s/filesail\n' "$bin_dir" >&2
    exit 1
fi

mkdir -p -- "$(dirname -- "$plugin_dir")" "$bin_dir"
ln -sfn -- "$project_dir/integrations/noctalia" "$plugin_dir"
install -Dm755 -- "$backend" "$bin_dir/filesail-backend"
install -Dm755 -- "$cli" "$bin_dir/filesail-cli"
if [[ ! -e "$bin_dir/filesail" && ! -L "$bin_dir/filesail" ]]; then
    ln -s -- "$project_dir/scripts/run.sh" "$bin_dir/filesail"
fi

printf 'Installed Noctalia plugin link: %s -> %s\n' "$plugin_dir" "$project_dir/integrations/noctalia"
printf 'Installed backend: %s/filesail-backend\n' "$bin_dir"
printf 'Installed control CLI: %s/filesail-cli\n' "$bin_dir"
printf 'Launcher available: %s/filesail\n' "$bin_dir"
printf 'Enable sergionoodles/filesail in Noctalia Settings > Plugins, then add its launcher widget to the bar.\n'
