"""Stage and atomically deploy the site, private installer and download API."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def deploy(release_directory, host='root@www.weitao-jiang.cn'):
    release_directory = Path(release_directory)
    metadata = json.loads((release_directory / 'release.json').read_text())
    with tempfile.TemporaryDirectory(prefix='circuitstudio-deploy-') as temp:
        staging = Path(temp)
        shutil.copytree(ROOT / 'Service', staging / 'Service', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        shutil.copytree(ROOT / 'Website', staging / 'Website', ignore=shutil.ignore_patterns('downloads', 'ASSETS.md', 'glass-sheets.png', 'schematic.png', 'illustration.png', 'blank.png'))
        # A content query changes whenever an asset changes, avoiding stale cached UI.
        for html in (staging / 'Website').glob('*.html'):
            text = html.read_text()
            import re
            for asset in ['style.css', 'app.js']:
                digest = hashlib.sha256((staging / 'Website' / asset).read_bytes()).hexdigest()[:12]
                text = re.sub(re.escape(asset) + r'\?v=[^"\s]+', asset + '?v=' + digest, text)
            for asset in (staging / 'Website/assets').iterdir():
                relative = 'assets/' + asset.name
                digest = hashlib.sha256(asset.read_bytes()).hexdigest()[:12]
                text = text.replace('"' + relative + '"', '"' + relative + '?v=' + digest + '"')
            html.write_text(text)
        (staging / 'Release').mkdir()
        for name in [metadata['file'], 'release.json', 'SHA256SUMS.txt']:
            shutil.copy2(release_directory / name, staging / 'Release' / name)
        remote = '/srv/circuitstudio-staging-' + metadata['version']
        transport = 'ssh -o ClearAllForwardings=yes -o BatchMode=yes'
        subprocess.run(['rsync', '-rt', '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r', '-e', transport, str(staging) + '/', host + ':' + remote + '/'], check=True)
        subprocess.run(['ssh', '-o', 'ClearAllForwardings=yes', '-o', 'BatchMode=yes', host,
                        'python3', remote + '/Service/install_server.py', '--staging', remote], check=True)
