#!/usr/bin/env python3
"""Exercise original-image preview loading in an isolated Quickshell host."""
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import zlib
from urllib.parse import unquote


SOURCE = Path(__file__).resolve().parents[1]
QS = shutil.which("qs") or shutil.which("quickshell")


def png(path, width, height, color):
    rows = b"".join(b"\0" + bytes(color) * width for _ in range(height))

    def chunk(name, data):
        return (struct.pack(">I", len(data)) + name + data
                + struct.pack(">I", zlib.crc32(name + data) & 0xffffffff))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def entry(path, width, height):
    stat = path.stat()
    return {"path": str(path), "url": path.as_uri(), "name": path.name,
            "size": stat.st_size, "modified": str(stat.st_mtime_ns),
            "mimeType": "image/png", "iconName": "image-x-generic",
            "imageWidth": width, "imageHeight": height}


class Host:
    def __init__(self, root, entries, second):
        self.root = root
        self.env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
                        FILESAIL_IMAGE_PREVIEW_ENTRIES=json.dumps(entries),
                        FILESAIL_IMAGE_PREVIEW_SECOND=json.dumps(second))
        self.shell = root / "host"
        self.shell.mkdir()
        (self.shell / "qml").symlink_to(SOURCE / "qml", target_is_directory=True)
        shutil.copy(SOURCE / "tests/image-preview/shell.qml", self.shell / "shell.qml")
        self.log = (root / "host.log").open("w+")
        self.process = subprocess.Popen([QS, "-p", str(self.shell), "--no-color"],
                                        env=self.env, stdout=self.log,
                                        stderr=subprocess.STDOUT)

    def call(self, method, *args):
        result = subprocess.run([QS, "ipc", "--path", str(self.shell), "call",
                                 "imagePreviewTest", method, *map(str, args)],
                                env=self.env, capture_output=True, text=True, timeout=4)
        if result.returncode != 0:
            raise AssertionError(f"IPC failed: {result.stderr}\n{self.log.name}\n{Path(self.log.name).read_text()}")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def wait(self, predicate, label):
        deadline = time.monotonic() + 8
        last = None
        while time.monotonic() < deadline:
            try:
                last = self.call("snapshot")
                if predicate(last):
                    return last
            except (AssertionError, json.JSONDecodeError):
                pass
            time.sleep(.05)
        self.log.flush()
        raise AssertionError(f"{label}: {last}\n{self.log.name}\n{Path(self.log.name).read_text()}")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.log.close()


def main():
    if not QS:
        raise SystemExit("Quickshell is required")
    with tempfile.TemporaryDirectory(prefix="filesail-image-preview-") as directory:
        root = Path(directory)
        first = root / "high resolution ü.png"
        second = root / "second image.png"
        third = root / "third image.png"
        png(first, 1600, 900, (20, 100, 220))
        png(second, 900, 1600, (220, 100, 20))
        png(third, 1200, 800, (100, 40, 180))
        host = Host(root, [entry(first, 1600, 900), entry(second, 900, 1600),
                          entry(third, 1200, 800)], entry(second, 900, 1600))
        try:
            first_url = unquote(first.as_uri())
            second_url = unquote(second.as_uri())
            initial = host.wait(lambda state: state["providerReadiness"] == "ready"
                                and state["probeReadiness"] == "ready", "initial image")
            assert initial["columns"] == 3
            assert math.isclose(initial["aspectRatio"], 1600 / 900)
            assert math.isclose(initial["tileWidth"] / initial["tileHeight"],
                                initial["gridAspectRatio"])
            assert initial["sourceUrl"] == first_url
            assert 1024 <= initial["decodedWidth"] <= 2048
            assert initial["decodedWidth"] == initial["decodedHeight"]
            initial_decode = (initial["decodedWidth"], initial["decodedHeight"])
            host.call("resizeProbe", 1100, 700)
            resized = host.wait(lambda state: state["probeWidth"] == 1100, "panel resize")
            assert (resized["decodedWidth"], resized["decodedHeight"]) == initial_decode

            previous_columns = 0
            for width in range(300, 1401, 50):
                host.call("resizeWindow", width, 420)
                resized_grid = host.wait(lambda state: state["windowWidth"] == width,
                                         f"grid width {width}")
                assert resized_grid["columns"] >= previous_columns
                previous_columns = resized_grid["columns"]

            host.call("resizeWindow", 300, 420)
            host.wait(lambda state: state["columns"] == 1, "thin preview panel")
            host.call("resizeWindow", 640, 900)
            portrait = host.wait(lambda state: state["columns"] <= 2, "portrait preview panel")
            assert portrait["columns"] == 2
            host.call("resizeWindow", 1200, 420)

            host.call("selectSecond")
            host.wait(lambda state: state["providerReadiness"] == "ready"
                      and state["sourceUrl"] == second_url, "selection switch")

            first.unlink()
            host.call("selectFirst", 1, "missing")
            failed = host.wait(lambda state: state["providerReadiness"] == "error", "missing image")
            assert "high resolution" in failed["providerError"]
            assert "high resolution" in failed["probeError"]

            png(first, 1600, 900, (40, 180, 80))
            before = failed["loadGeneration"]
            host.call("selectFirst", first.stat().st_size, first.stat().st_mtime_ns)
            refreshed = host.wait(lambda state: state["providerReadiness"] == "ready", "same-path refresh")
            assert refreshed["sourceUrl"] == first_url
            assert refreshed["loadGeneration"] > before
            host.log.flush()
            runtime_log = Path(host.log.name).read_text()
            assert not any(error in runtime_log for error in
                           ["Binding loop", "ReferenceError", "TypeError"]), runtime_log
            print("PASS: original image preview")
        finally:
            host.close()


if __name__ == "__main__":
    main()
