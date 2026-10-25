#!/usr/bin/env python3
"""Package the original offline editor without upstream sources or overlays."""
import hashlib
import json
import shutil
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'Engineering/Independent'
output = ROOT / 'Resources/EngineeringEditor'
staging = output.with_name('EngineeringEditor.staging')
if staging.exists():
    shutil.rmtree(staging)
staging.mkdir(parents=True)
for path in source.iterdir():
    if path.suffix in {'.html', '.css', '.mjs', '.json'} and not path.name.endswith('.test.mjs') and not path.name.startswith('acceptance-'):
        shutil.copy2(path, staging / path.name)
for origin, destination in [
    ('Engineering/PDK', 'pdk'),
    ('Engineering/CourseCAD', 'course-cad'),
    ('Engineering/Markdown', 'markdown'),
    ('Sources/CircuitCore/Resources/Fonts', 'fonts'),
]:
    shutil.copytree(ROOT / origin, staging / destination)
manifest = {
    'implementation': 'Circuit Studio independent editor v1',
    'license': 'MIT',
    'files': {str(p.relative_to(staging)):hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(staging.rglob('*')) if p.is_file()},
    'thirdParty': ['Metropolis (Unlicense)', 'markdown-it (MIT)', 'KaTeX (MIT)',
                   'GF180MCU and SKY130 public models (Apache-2.0)'],
}
(staging / 'SOURCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
if output.exists():
    shutil.rmtree(output)
staging.rename(output)
print(f'Packaged independent editor: {output} ({len(manifest["files"])} files)')
