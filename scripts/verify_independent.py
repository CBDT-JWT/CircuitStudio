#!/usr/bin/env python3
"""Exercise the original editor through its real native bridge and solver."""
from pathlib import Path
import json, platform, plistlib, shutil, subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
evidence=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.home()/'Library/Caches/CircuitStudioQA/Build32/web-native'
evidence.parent.mkdir(parents=True,exist_ok=True)
work=Path(tempfile.mkdtemp(prefix='native-checks-',dir=evidence.parent))
partial=work/'DocumentTypes.swift'
partial.write_text((root/'Sources/CircuitStudio/Documents.swift').read_text().split('#if !CIRCUITSTUDIO_PREVIEW')[0])
app=work/'EditorChecks.app';contents=app/'Contents';binary=contents/'MacOS/EditorChecks';binary.parent.mkdir(parents=True)
resources=contents/'Resources';resources.mkdir()
for name in ['Fonts']:shutil.copytree(root/'Sources/CircuitCore/Resources'/name,resources/name)
shutil.copytree(root/'Resources/EngineeringEditor',resources/'EngineeringEditor')
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'EditorChecks','CFBundleIdentifier':'com.circuitstudio.editorchecks','CFBundlePackageType':'APPL'}))
files=list((root/'Sources/CircuitCore').glob('*.swift'))+[p for p in (root/'Sources/CircuitStudio').glob('*.swift') if p.name not in ['Documents.swift','PreviewApp.swift']]
spice=root/'Vendor/ngspice/NgSpice.xcframework/macos-arm64_x86_64'
command=['xcrun','swiftc','-swift-version','6','-parse-as-library','-target',platform.machine()+'-apple-macos26.0','-I',str(spice/'Headers')]+[str(p) for p in files]+[str(partial),str(root/'scripts/verify_independent.swift'),str(spice/'libngspice.a'),'-lc++','-o',str(binary)]
subprocess.run(command,check=True)
subprocess.run([str(binary),str(evidence)],check=True)
