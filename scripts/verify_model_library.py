#!/usr/bin/env python3
"""Run every bundled real PDK packet in the same static ngspice used by the app."""
from pathlib import Path
import platform, subprocess, sys, tempfile
root=Path(__file__).resolve().parents[1]
work=Path(tempfile.mkdtemp(prefix='circuitstudio-models-'))
spice=root/'Vendor/ngspice/NgSpice.xcframework/macos-arm64_x86_64'
binary=work/'ModelChecks'
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-target',platform.machine()+'-apple-macos26.0','-I',str(spice/'Headers'),*[str(p) for p in (root/'Sources/CircuitCore').glob('*.swift')],str(root/'scripts/verify_model_library.swift'),str(spice/'libngspice.a'),'-lc++','-o',str(binary)],check=True)
output=work/'results.json'
subprocess.run([str(binary),str(root),str(output),*sys.argv[1:]],check=True)
print('Evidence:',output)
