#!/usr/bin/env python3
"""Interactive protocol coverage for queued and running mutation cancellation."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import shutil


def test_cross_device_move(backend: str) -> None:
    shared_memory = Path("/dev/shm")
    if not shared_memory.is_dir():
        print("SKIP: cross-device cancellation fixture is unavailable")
        return
    source_root = Path(tempfile.mkdtemp(prefix="filesail-xmove-", dir="/tmp"))
    destination_root = Path(tempfile.mkdtemp(prefix="filesail-xmove-", dir=shared_memory))
    try:
        if os.stat(source_root).st_dev == os.stat(destination_root).st_dev:
            print("SKIP: /tmp and /dev/shm are on the same device")
            return
        source = source_root / "source"
        source.mkdir()
        (source / "payload").write_bytes(b"x" * (16 * 1024 * 1024))
        environment = os.environ.copy()
        environment["FILESAIL_DEV_TRANSFER_DELAY_MS"] = "10"
        process = subprocess.Popen(
            [backend, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1, env=environment)
        assert process.stdin is not None and process.stdout is not None

        def send(message):
            process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            process.stdin.flush()

        send({"id": 201, "method": "move", "params": {
            "paths": [str(source)], "targetDirectory": str(destination_root)}})
        messages = []
        cancel_sent = False
        while True:
            message = json.loads(process.stdout.readline())
            messages.append(message)
            if message.get("event") == "operationChanged":
                operation = message["operation"]
                if int(operation.get("progress", {}).get("bytesDone", "0")) > 0 and not cancel_sent:
                    send({"id": 202, "method": "operations.cancel", "params": {
                        "operationId": 201, "backendInstance": message["backendInstance"]}})
                    cancel_sent = True
            if ({201, 202} <= {item.get("id") for item in messages if "id" in item}):
                break
        process.stdin.close()
        process.wait(timeout=5)
        response = next(item for item in messages if item.get("id") == 201)
        assert response["errorCode"] == "cancelled"
        assert source.exists() and not (destination_root / "source").exists()
        assert not list(source_root.glob(".filesail-move-*"))
        assert not list(destination_root.glob(".filesail-copy-*"))
    finally:
        shutil.rmtree(source_root, ignore_errors=True)
        shutil.rmtree(destination_root, ignore_errors=True)


def main() -> int:
    backend = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="filesail-cancel-") as temporary:
        root = Path(temporary)
        source = root / "source"
        destination = root / "destination"
        source.mkdir()
        destination.mkdir()
        (source / "payload").write_bytes(b"x" * (16 * 1024 * 1024))

        environment = os.environ.copy()
        environment["FILESAIL_DEV_TRANSFER_DELAY_MS"] = "10"
        process = subprocess.Popen(
            [backend, "--serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1, env=environment)
        assert process.stdin is not None and process.stdout is not None

        def send(message):
            process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            process.stdin.flush()

        send({"id": 1, "method": "copy", "params": {
            "paths": [str(source)], "targetDirectory": str(destination)}})
        send({"id": 2, "method": "mkdir", "params": {
            "parent": str(root), "name": "must-not-exist"}})

        messages = []
        instance = ""
        queued_cancel_sent = False
        running_cancel_sent = False
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            messages.append(message)
            if message.get("event") == "operationChanged":
                operation = message["operation"]
                instance = message["backendInstance"]
                assert "canCancel" in operation
                assert "cancelMode" in operation
                assert "cancellationRequested" in operation
                if operation["id"] == 2 and operation["state"] == "queued" and not queued_cancel_sent:
                    send({"id": 102, "method": "operations.cancel", "params": {
                        "operationId": 2, "backendInstance": instance}})
                    queued_cancel_sent = True
                progress = operation.get("progress", {})
                if (operation["id"] == 1 and int(progress.get("bytesDone", "0")) > 0
                        and not running_cancel_sent):
                    send({"id": 101, "method": "operations.cancel", "params": {
                        "operationId": 1, "backendInstance": instance}})
                    running_cancel_sent = True
            terminal_ids = {item.get("id") for item in messages if "id" in item}
            if {1, 2, 101, 102}.issubset(terminal_ids):
                break

        send({"id": 103, "method": "operations.cancel", "params": {
            "operationId": 1, "backendInstance": instance}})
        send({"id": 104, "method": "operations.cancel", "params": {
            "operationId": 1, "backendInstance": "stale"}})
        send({"id": 105, "method": "operations.cancel", "params": {
            "operationId": 1.5, "backendInstance": instance}})
        while {103, 104, 105} - {item.get("id") for item in messages}:
            messages.append(json.loads(process.stdout.readline()))

        process.stdin.close()
        process.wait(timeout=5)
        responses = {item["id"]: item for item in messages if "id" in item}
        assert responses[1]["errorCode"] == "cancelled"
        assert responses[2]["errorCode"] == "cancelled"
        assert responses[101]["accepted"] is True
        assert responses[102]["accepted"] is True
        assert responses[103]["accepted"] is False and responses[103]["reason"] == "not_active"
        assert responses[104]["errorCode"] == "stale_backend_instance"
        assert responses[105]["errorCode"] == "invalid_params"
        assert not (root / "must-not-exist").exists()
        assert not (destination / "source").exists()
        assert (source / "payload").exists()
        assert not list(destination.glob(".filesail-copy-*"))
        assert sum(item.get("id") == 1 for item in messages) == 1
        assert sum(item.get("id") == 2 for item in messages) == 1
    test_cross_device_move(backend)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
