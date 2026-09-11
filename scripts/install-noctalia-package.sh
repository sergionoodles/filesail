#!/usr/bin/env bash
set -euo pipefail

plugin_source=/usr/share/filesail/noctalia-plugin
if [[ ! -d "$plugin_source" ]]; then
    printf 'FileSail Noctalia plugin payload not found: %s\n' "$plugin_source" >&2
    exit 1
fi

noctalia_data_home="${NOCTALIA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
plugin_dir="${noctalia_data_home%/}/noctalia/plugins/filesail"

if [[ -e "$plugin_dir" && ! -L "$plugin_dir" ]]; then
    printf 'Refusing to replace existing non-symlink plugin directory: %s\n' "$plugin_dir" >&2
    exit 1
fi

mkdir -p -- "$(dirname -- "$plugin_dir")"
ln -sfn -- "$plugin_source" "$plugin_dir"

printf 'Installed FileSail Noctalia plugin link: %s -> %s\n' "$plugin_dir" "$plugin_source"
printf '%s\n' 'Enable sergionoodles/filesail in Noctalia Settings > Plugins, then add its launcher widget to the bar.'
printf '%s\n' 'Clicking the widget opens the native browser panel; use Open full manager for the complete FileSail window.'
