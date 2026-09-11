#!/usr/bin/env bash
set -euo pipefail

# Build the Arch package from this working tree, including uncommitted edits.
# The repository PKGBUILD intentionally follows the remote Git source, so a
# temporary source archive and temporary PKGBUILD are used for local testing.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: scripts/makepkg_local.sh [options]

Creates an Arch package from the current working tree. Local makepkg options
may be passed through; --install additionally installs the resulting package.

Examples:
  scripts/makepkg_local.sh
  scripts/makepkg_local.sh --install
  scripts/makepkg_local.sh --install --nocheck
EOF
}

command -v makepkg >/dev/null 2>&1 || {
    printf '%s\n' 'makepkg_local.sh: makepkg was not found' >&2
    exit 1
}
command -v tar >/dev/null 2>&1 || {
    printf '%s\n' 'makepkg_local.sh: tar was not found' >&2
    exit 1
}

makepkg_options=(-C -f -s)
while (($#)); do
    case "$1" in
        --install)
            makepkg_options+=(-i)
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            makepkg_options+=("$1")
            shift
            ;;
    esac
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/filesail-makepkg.XXXXXX")"
output_dir="${FILESAIL_LOCAL_PKGDEST:-$project_dir/dist}"
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

# Prefix every archive member with the directory name expected by the
# repository PKGBUILD. Build products and VCS metadata must not enter the
# package source snapshot.
tar \
    --exclude='./.git' \
    --exclude='./build' \
    --exclude='./build-*' \
    --exclude='./dist' \
    --transform='s,^,filesail-checkout/,' \
    -C "$project_dir" \
    -caf "$work_dir/filesail-checkout.tar.zst" .

cp -- "$project_dir/PKGBUILD" "$work_dir/PKGBUILD"
ln -s -- "$project_dir/scripts" "$work_dir/scripts"
ln -s -- "$project_dir/VERSION" "$work_dir/VERSION"
sed -i "s|^source=.*|source=('filesail-checkout.tar.zst')|" "$work_dir/PKGBUILD"

(
    cd -- "$work_dir"
    makepkg "${makepkg_options[@]}" -p PKGBUILD
)

shopt -s nullglob
packages=("$work_dir"/dist/*.pkg.tar.*)
if ((${#packages[@]} == 0)); then
    printf '%s\n' 'makepkg_local.sh: makepkg produced no package' >&2
    exit 1
fi

mkdir -p -- "$output_dir"
copied_packages=()
for package in "${packages[@]}"; do
    destination="$output_dir/$(basename -- "$package")"
    cp -- "$package" "$destination"
    copied_packages+=("$destination")
done

printf 'Created local package:\n'
for package in "${copied_packages[@]}"; do
    printf '  %s\n' "$package"
done
