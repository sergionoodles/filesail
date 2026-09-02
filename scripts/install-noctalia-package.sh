#!/usr/bin/env bash
set -euo pipefail

plugin_source=/usr/share/filesail/noctalia-plugin
if [[ ! -d "$plugin_source" ]]; then
    printf 'FileSail Noctalia plugin payload not found: %s\n' "$plugin_source" >&2
    exit 1
fi

noctalia_config_dir="${NOCTALIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/noctalia}"
noctalia_config_dir="${noctalia_config_dir%/}"
plugin_dir="$noctalia_config_dir/plugins/filesail"

if [[ -e "$plugin_dir" && ! -L "$plugin_dir" ]]; then
    printf 'Refusing to replace existing non-symlink plugin directory: %s\n' "$plugin_dir" >&2
    exit 1
fi

mkdir -p -- "$(dirname -- "$plugin_dir")"
ln -sfn -- "$plugin_source" "$plugin_dir"

printf 'Installed FileSail Noctalia plugin link: %s -> %s\n' "$plugin_dir" "$plugin_source"
printf '%s\n' 'Enable FileSail in Noctalia Settings > Plugins, then add it to the bar.'
