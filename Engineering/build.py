#!/usr/bin/env python3
"""Package the original offline editor without upstream sources or overlays."""
import hashlib
import json
import shutil
import re
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'Engineering/Independent'
output = ROOT / 'Resources/EngineeringEditor'
cache = Path.home() / 'Library/Caches/CircuitStudioPackaging'
cache.mkdir(parents=True, exist_ok=True)
temporary = tempfile.TemporaryDirectory(prefix='editor-', dir=cache)
staging = Path(temporary.name)
runtime = ['index.html', 'studio.css', 'agent.mjs', 'editor.mjs', 'icons.mjs',
           'importer.mjs', 'interaction.mjs', 'editing.mjs', 'text-editor.mjs', 'model.mjs', 'renderer.mjs',
           'symbols.mjs', 'symbol-artwork.mjs', 'symbol-artwork-data.mjs', 'course-layouts.json']
for name in runtime:
    shutil.copy2(source / name, staging / name)
for origin, destination in [
    ('Engineering/Independent/graphics', 'graphics'),
    ('Engineering/PDK', 'pdk'),
    ('Engineering/CourseCAD', 'course-cad'),
    ('Engineering/Markdown', 'markdown'),
    ('Sources/CircuitCore/Resources/Fonts', 'fonts'),
]:
    if any(re.search(r' \d+(?=\.[^.]+$|$)', p.name) for p in (ROOT / origin).rglob('*')):
        raise SystemExit('Resolve duplicate source resources before packaging: ' + origin)
    shutil.copytree(ROOT / origin, staging / destination)
manifest = {
    'implementation': 'Circuit Studio independent editor with separately licensed vector graphics',
    'license': 'MIT editor code; graphic data has its separate bundled license',
    'referenceGraphicsBundled': True,
    'files': {str(p.relative_to(staging)):hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(staging.rglob('*')) if p.is_file()},
    'thirdParty': ['Reference vector graphics (AGPL-3.0)', 'Metropolis (Unlicense)', 'markdown-it (MIT)', 'KaTeX (MIT)',
                   'GF180MCU and SKY130 public models (Apache-2.0)'],
}
(staging / 'SOURCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
known = set(manifest['files']) | {'SOURCE.json'}
previous = output / 'SOURCE.json'
old = json.loads(previous.read_text()).get('files', {}) if previous.exists() else {}
old = set(old) if isinstance(old, dict) else set()
unexpected = [p for p in output.rglob('*') if p.is_file() and str(p.relative_to(output)) not in known | old]
if unexpected:
    raise SystemExit('Unexpected resource files; move them aside before building: ' + ', '.join(str(p.relative_to(output)) for p in unexpected[:8]))
# Update files in place: replacing a synchronized directory can create duplicate
# conflict copies. Unchanged dependency/model bytes are never rewritten.
for name in sorted(known):
    target = output / name
    target.parent.mkdir(parents=True, exist_ok=True)
    data = (staging / name).read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)
for name in old - known:
    (output / name).unlink(missing_ok=True)
temporary.cleanup()
print(f'Packaged independent editor: {output} ({len(manifest["files"])} files)')
