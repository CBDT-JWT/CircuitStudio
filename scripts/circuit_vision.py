#!/usr/bin/env python3
"""Run the Mac-only training tool using Xcode; no pip dependencies required."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
build = root / "build" / "circuit-vision"
build.mkdir(parents=True, exist_ok=True)
executable = build / "circuit-vision"
sources = sorted((root / "Sources" / "CircuitCore").glob("*.swift"))
sources.append(root / "scripts" / "circuit_vision.swift")
if not executable.exists() or any(p.stat().st_mtime > executable.stat().st_mtime for p in sources):
    if os.uname().machine != "arm64":
        raise SystemExit("This training wrapper currently requires an Apple Silicon Mac.")
    spice = root / "Vendor" / "ngspice" / "NgSpice.xcframework" / "macos-arm64_x86_64"
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-I", str(spice / "Headers"),
                    "-L", str(spice), "-lngspice", "-lc++", *map(str, sources), "-o", str(executable)], check=True)
subprocess.run([str(executable), *sys.argv[1:]], check=True)
