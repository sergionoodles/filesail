#!/usr/bin/env bash
set -euo pipefail

test_dir="$(mktemp -d /tmp/filesail-launcher-test.XXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -- "$test_dir/bin"
cat > "$test_dir/bin/qs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$FILESAIL_TEST_ARGUMENTS"
EOF
chmod +x -- "$test_dir/bin/qs"
export PATH="$test_dir/bin:$PATH"
export FILESAIL_QS="$test_dir/bin/qs"
export FILESAIL_BACKEND="$test_dir/bin/qs"
export FILESAIL_TEST_ARGUMENTS="$test_dir/arguments"
export XDG_RUNTIME_DIR=""

for launcher in "$@"; do
    export TMPDIR="$test_dir/private"
    mkdir -- "$TMPDIR"
    bash "$launcher" --path "$test_dir"
    runtime_dir="$TMPDIR/filesail-runtime-$UID"
    [[ -d "$runtime_dir" && ! -L "$runtime_dir" && -O "$runtime_dir" ]]
    [[ $(stat -c '%a' -- "$runtime_dir") == 700 ]]
    [[ -f "$runtime_dir/filesail-$UID.lock" ]]
    # A subsequent invocation must reuse the same lock directory.
    bash "$launcher" --path "$test_dir"
    rm -rf -- "$TMPDIR"

    export TMPDIR="$test_dir/symlink"
    mkdir -- "$TMPDIR" "$TMPDIR/target"
    ln -s -- "$TMPDIR/target" "$TMPDIR/filesail-runtime-$UID"
    if bash "$launcher" --path "$test_dir" >"$test_dir/error" 2>&1; then
        printf 'launcher accepted a symlink runtime directory\n' >&2
        exit 1
    fi
    [[ ! -e "$TMPDIR/target/filesail-$UID.lock" ]]
    grep -q 'unsafe runtime directory' "$test_dir/error"
    rm -rf -- "$TMPDIR"

    export TMPDIR="$test_dir/shared"
    mkdir -- "$TMPDIR" "$TMPDIR/filesail-runtime-$UID"
    chmod 777 -- "$TMPDIR/filesail-runtime-$UID"
    if bash "$launcher" --path "$test_dir" >"$test_dir/error" 2>&1; then
        printf 'launcher accepted a shared runtime directory\n' >&2
        exit 1
    fi
    [[ ! -e "$TMPDIR/filesail-runtime-$UID/filesail-$UID.lock" ]]
    rm -rf -- "$TMPDIR"

    : > "$FILESAIL_TEST_ARGUMENTS"
    bash "$launcher" --new-instance --path "$test_dir"
    # Quickshell accepts duplicate instances by default; neither duplicate
    # flag should be passed for the diagnostic launcher option.
    if grep -Eq '^--(allow|no)-duplicate$' "$FILESAIL_TEST_ARGUMENTS"; then
        printf 'new-instance passed an incorrect Quickshell option\n' >&2
        exit 1
    fi
    grep -qx -- '-p' "$FILESAIL_TEST_ARGUMENTS"
done
