#!/usr/bin/env python3
"""Install the download service and marketing site on the owner's Linux server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import sqlite3
import subprocess
import tarfile
from datetime import datetime, timezone
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--staging', type=Path, required=True)
args = parser.parse_args()
if os.geteuid() != 0:
    parser.error('Run this installer through the configured root SSH connection.')
staging = args.staging.resolve()
root = Path('/srv/circuitstudio')
site = Path('/srv/homepage/Home/static/circuit-studio')
root.mkdir(parents=True, exist_ok=True)
backup = root / 'backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')
backup.mkdir(parents=True, exist_ok=True)
backup.chmod(0o700)
backup.parent.chmod(0o700)
contact_database = root / 'data/downloads.sqlite3'
if contact_database.exists():
    with sqlite3.connect(contact_database) as source_db, sqlite3.connect(backup / 'downloads.sqlite3') as backup_db:
        source_db.backup(backup_db)
    (backup / 'downloads.sqlite3').chmod(0o600)
if site.exists():
    with tarfile.open(backup / 'website.tar.gz', 'w:gz') as archive:
        archive.add(site, arcname='circuit-studio')
else:
    site.mkdir(parents=True)
metadata = json.loads((staging / 'Release/release.json').read_text())
name = metadata['file']
if not re.fullmatch(r'CircuitStudio-[0-9A-Za-z.+-]+-universal\.dmg', name):
    raise RuntimeError('Invalid archive filename')
archive = staging / 'Release' / name
if archive.stat().st_size != metadata['bytes'] or hashlib.sha256(archive.read_bytes()).hexdigest() != metadata['sha256']:
    raise RuntimeError('The uploaded installer failed checksum validation')
releases = root / 'releases'; releases.mkdir(exist_ok=True)
destination = releases / name
if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() != metadata['sha256']:
    raise RuntimeError('A different installer already exists for this version; publish a new version')


def atomic_copy(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    pending = target.with_name('.' + target.name + '.new')
    shutil.copyfile(source, pending)
    pending.chmod(mode)
    os.replace(pending, target)


def atomic_text(text, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    pending = target.with_name('.' + target.name + '.new')
    pending.write_text(text); pending.chmod(mode); os.replace(pending, target)


atomic_copy(archive, destination)
atomic_copy(staging / 'Release/release.json', releases / 'release.json')
try:
    account = pwd.getpwnam('circuitstudio')
except KeyError:
    subprocess.run(['useradd', '--system', '--home-dir', str(root), '--shell', '/usr/sbin/nologin', 'circuitstudio'], check=True)
    account = pwd.getpwnam('circuitstudio')
data = root / 'data'; data.mkdir(exist_ok=True)
data.chmod(0o700); os.chown(data, account.pw_uid, account.pw_gid)
service = root / 'service'; service.mkdir(exist_ok=True)
changed = False
for name in ['server.py', 'contacts.py', 'requirements.txt']:
    source = staging / 'Service' / name
    target = service / name
    changed = changed or not target.exists() or source.read_bytes() != target.read_bytes()
    atomic_copy(source, target)
venv = root / 'venv'
if not (venv / 'bin/python').exists():
    subprocess.run(['python3', '-m', 'venv', str(venv)], check=True)
requirements_hash = hashlib.sha256((service / 'requirements.txt').read_bytes()).hexdigest()
lock = venv / '.requirements.sha256'
if not lock.exists() or lock.read_text() != requirements_hash:
    subprocess.run([str(venv / 'bin/pip'), 'install', '-r', str(service / 'requirements.txt')], check=True)
    lock.write_text(requirements_hash); changed = True
environment = Path('/etc/circuitstudio-downloads.env')
if not environment.exists():
    atomic_text('CS_CONTACT_DB=/srv/circuitstudio/data/downloads.sqlite3\nCS_RELEASE_DIR=/srv/circuitstudio/releases\nCS_SITE_ORIGIN=https://www.weitao-jiang.cn,https://weitao-jiang.cn\nCS_RATE_SALT=' + secrets.token_hex(32) + '\n', environment, 0o600)
    changed = True
unit = '''[Unit]
Description=Circuit Studio private download registry
After=network.target

[Service]
User=circuitstudio
Group=circuitstudio
WorkingDirectory=/srv/circuitstudio/service
EnvironmentFile=/etc/circuitstudio-downloads.env
ExecStart=/srv/circuitstudio/venv/bin/gunicorn --bind 127.0.0.1:5087 --workers 2 --threads 4 --timeout 120 --access-logfile - --error-logfile - "server:create_app()"
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/srv/circuitstudio/data

[Install]
WantedBy=multi-user.target
'''
unit_path = Path('/etc/systemd/system/circuitstudio-downloads.service')
changed = changed or not unit_path.exists() or unit_path.read_text() != unit
atomic_text(unit, unit_path)
subprocess.run(['systemctl', 'daemon-reload'], check=True)
active = subprocess.run(['systemctl', 'is-active', '--quiet', 'circuitstudio-downloads']).returncode == 0
if not active:
    subprocess.run(['systemctl', 'enable', '--now', 'circuitstudio-downloads'], check=True)
elif changed:
    subprocess.run(['systemctl', 'restart', 'circuitstudio-downloads'], check=True)
import time
for attempt in range(30):
    try:
        with urllib.request.urlopen('http://127.0.0.1:5087/api/stats', timeout=3) as response:
            if response.status == 200: break
    except Exception:
        if attempt == 29: raise
        time.sleep(.3)

# HTML is replaced last, after its referenced assets and API are ready.
for path in (staging / 'Website').rglob('*'):
    if not path.is_file() or path.name == 'index.html': continue
    relative = path.relative_to(staging / 'Website')
    if relative.suffix == '.dmg': continue
    atomic_copy(path, site / relative)
(site / 'downloads').mkdir(exist_ok=True)
atomic_copy(staging / 'Release/release.json', site / 'downloads/release.json')
atomic_copy(staging / 'Release/SHA256SUMS.txt', site / 'downloads/SHA256SUMS.txt')

nginx = Path('/etc/nginx/sites-enabled/homepage').resolve()
original = nginx.read_text()
shutil.copy2(nginx, backup / 'nginx-homepage.conf')
locations = '''    # BEGIN CIRCUIT STUDIO
    location = /static/circuit-studio/api/request-download {
        client_max_body_size 2k;
        limit_req zone=circuitstudio_email burst=3 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:5087/api/request-download;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
    location ^~ /static/circuit-studio/api/ {
        proxy_pass http://127.0.0.1:5087/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
    location ^~ /static/circuit-studio/assets/ {
        alias /srv/homepage/Home/static/circuit-studio/assets/;
        expires 30d;
    }
    location ^~ /static/circuit-studio/ {
        alias /srv/homepage/Home/static/circuit-studio/;
        index index.html;
        expires -1;
    }
    # END CIRCUIT STUDIO
'''
if '# BEGIN CIRCUIT STUDIO' in original:
    updated = re.sub(r'    # BEGIN CIRCUIT STUDIO.*?    # END CIRCUIT STUDIO\n', locations, original, flags=re.S)
else:
    marker = '    location /static {'
    if original.count(marker) != 1: raise RuntimeError('Cannot identify the homepage static location')
    updated = original.replace(marker, locations + '\n' + marker, 1)
zone = Path('/etc/nginx/conf.d/circuitstudio-downloads.conf')
zone_text = 'limit_req_zone $binary_remote_addr zone=circuitstudio_email:1m rate=6r/m;\n'
zone_original = zone.read_text() if zone.exists() else None
atomic_text(zone_text, zone)
atomic_text(updated, nginx)
try:
    subprocess.run(['nginx', '-t'], check=True)
except Exception:
    atomic_text(original, nginx)
    if zone_original is not None: atomic_text(zone_original, zone)
    else: zone.unlink()
    raise
if updated != original or zone_original != zone_text:
    subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
atomic_copy(staging / 'Website/index.html', site / 'index.html')
print('Published Circuit Studio', metadata['version'])
print('Website: https://www.weitao-jiang.cn/static/circuit-studio/')
print('Private contact database: /srv/circuitstudio/data/downloads.sqlite3')
print('Backup:', backup)
