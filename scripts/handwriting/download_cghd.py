"""Fetch one photograph per drawing from the official CGHD v2 archive.

Range requests avoid downloading the other three photographs and segmentations.
No archive paths are trusted; only requested image/XML entries are written.
"""
import argparse
import concurrent.futures
import json
import pathlib
import struct
import threading
import time
import urllib.request
import zlib

URL = "https://zenodo.org/records/6448277/files/cghd.zip"
SIZE = 1583844833
lock = threading.Lock()
next_request = 0.0


def request(start, end):
    global next_request
    for attempt in range(5):
        with lock:
            delay = max(0, next_request - time.monotonic())
            next_request = max(next_request, time.monotonic()) + 0.65
        time.sleep(delay)
        try:
            req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end}", "User-Agent": "CircuitStudio-research/1.0"})
            with urllib.request.urlopen(req, timeout=60) as response:
                if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {start}-"):
                    raise ValueError("Server did not honor the byte range")
                return response.read()
        except Exception:
            if attempt == 4:
                raise
            time.sleep(10 * (attempt + 1))


def index():
    tail = request(SIZE - 65536, SIZE - 1)
    eocd = struct.unpack_from("<4s4H2LH", tail, tail.rfind(b"PK\x05\x06"))
    raw = request(eocd[6], eocd[6] + eocd[5] - 1)
    entries, p = [], 0
    while raw[p:p + 4] == b"PK\x01\x02":
        v = struct.unpack_from("<4s6H3L5H2L", raw, p)
        n, e, c = v[10:13]
        entries.append(dict(name=raw[p + 46:p + 46 + n].decode(), method=v[4], crc=v[7], compressed=v[8], size=v[9], offset=v[16]))
        p += 46 + n + e + c
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    metadata = args.destination / "zip-index.json"
    entries = json.loads(metadata.read_text()) if metadata.exists() else index()
    metadata.write_text(json.dumps(entries))
    selected = [e for e in entries if ("/images/" in e["name"] and pathlib.PurePosixPath(e["name"]).stem.endswith("_P1") and pathlib.PurePosixPath(e["name"]).suffix.lower() in [".jpg", ".jpeg", ".png"]) or ("/annotations/" in e["name"] and e["name"].endswith("_P1.xml")) or e["name"] in ["classes.json", "README.md"]]

    def fetch(entry, block=None, block_start=0):
        relative = pathlib.PurePosixPath(entry["name"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe archive path")
        target = args.destination / relative
        if target.exists() and target.stat().st_size == entry["size"]:
            return
        raw = block[entry["offset"] - block_start:] if block is not None else request(entry["offset"], min(SIZE - 1, entry["offset"] + 30 + len(entry["name"].encode()) + 512 + entry["compressed"]))
        v = struct.unpack_from("<4s5H3L2H", raw)
        if v[0] != b"PK\x03\x04":
            raise ValueError("Invalid zip entry")
        p = 30 + v[-2] + v[-1]
        content = raw[p:p + entry["compressed"]]
        if entry["method"] == 8:
            content = zlib.decompress(content, -15)
        if len(content) != entry["size"] or zlib.crc32(content) != entry["crc"]:
            raise ValueError("Corrupt zip entry")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    # XML entries are contiguous within each writer. One range per writer avoids
    # hundreds of tiny requests to the research data server.
    for writer in sorted({e["name"].split("/")[0] for e in selected if e["name"].endswith(".xml")}):
        group = [e for e in selected if e["name"].startswith(writer + "/") and e["name"].endswith(".xml")]
        if all((args.destination / e["name"]).exists() for e in group):
            continue
        start = min(e["offset"] for e in group)
        end = max(e["offset"] + 30 + len(e["name"].encode()) + 512 + e["compressed"] for e in group)
        block = request(start, end)
        for entry in group:
            fetch(entry, block, start)
        print(f"Annotations: {writer}", flush=True)
    selected = [e for e in selected if not e["name"].endswith(".xml")]
    selected.sort(key=lambda e: e["offset"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for i, _ in enumerate(pool.map(fetch, selected), 1):
            if i % 40 == 0 or i == len(selected):
                print(f"Downloaded {i}/{len(selected)} entries", flush=True)


if __name__ == "__main__":
    main()
