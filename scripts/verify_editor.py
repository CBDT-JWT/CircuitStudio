#!/usr/bin/env python3
"""Compile the actual Mac editor and run interaction checks with bundled artwork."""
from pathlib import Path
import json, platform, plistlib, shutil, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
work=Path(tempfile.mkdtemp(prefix='circuitstudio-editor-checks-'))
partial=work/'DocumentTypes.swift'
partial.write_text((root/'Sources/CircuitStudio/Documents.swift').read_text().split('#if !CIRCUITSTUDIO_PREVIEW')[0])
app=work/'EditorChecks.app';contents=app/'Contents';binary=contents/'MacOS/EditorChecks';binary.parent.mkdir(parents=True)
resources=contents/'Resources';resources.mkdir()
for name in ['Fonts']:shutil.copytree(root/'Sources/CircuitCore/Resources'/name,resources/name)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'EditorChecks','CFBundleIdentifier':'com.circuitstudio.editorchecks','CFBundlePackageType':'APPL'}))
files=list((root/'Sources/CircuitCore').glob('*.swift'))+[p for p in (root/'Sources/CircuitStudio').glob('*.swift') if p.name not in ['Documents.swift','PreviewApp.swift']]
spice=root/'Vendor/ngspice/NgSpice.xcframework/macos-arm64_x86_64'
command=['xcrun','swiftc','-swift-version','6','-parse-as-library','-target',platform.machine()+'-apple-macos26.0','-I',str(spice/'Headers')]+[str(p) for p in files]+[str(partial),str(root/'scripts/verify_editor.swift'),str(spice/'libngspice.a'),'-lc++','-o',str(binary)]
subprocess.run(command,check=True)
subprocess.run([str(binary),str(work/'results.json')],check=True)
print('Evidence:',work/'results.json')
