#!/usr/bin/env bash
set -euo pipefail

helper="$1"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/filesail-clipboard-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

HELPER="$helper" python3 - <<'PY'
import json
import os
import select
import subprocess
import time

helper = os.environ["HELPER"]
process = subprocess.Popen(
    [helper, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, bufsize=1, env={**os.environ, "WAYLAND_DISPLAY": ""})

def read_message(timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if ready:
            line = process.stdout.readline()
            if line:
                return json.loads(line)
    raise AssertionError("clipboard helper did not produce a message")

first = read_message()
assert first.get("event") == "changed"
process.stdin.write('{"id":1,"method":"capabilities","params":{}}\n')
process.stdin.flush()
process.stdin.write('{"id":2,"method":"snapshot","params":{}}')
process.stdin.flush()
time.sleep(0.03)
process.stdin.write('\n')
process.stdin.flush()

responses = {}
while 1 not in responses or 2 not in responses:
    message = read_message()
    if "id" in message:
        responses[message["id"]] = message
assert responses[1]["ok"] is True
assert responses[2]["ok"] is True
assert responses[2]["state"] == "unavailable"
process.stdin.close()
assert process.wait(timeout=2) == 0
PY
