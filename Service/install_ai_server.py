#!/usr/bin/env python3
"""Deploy the isolated AI relay; preserve all existing provider keys and access codes."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import subprocess
import time
import urllib.request
import ssl


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    args=parser.parse_args()
    if os.geteuid()!=0: parser.error('Run on the server as root.')
    root=Path('/srv/circuitstudio-ai'); root.mkdir(exist_ok=True); root.chmod(0o755)
    backup=root/'backups'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S'); backup.mkdir(parents=True,exist_ok=True); backup.parent.chmod(0o700)
    try: account=pwd.getpwnam('circuitstudio-ai')
    except KeyError:
        subprocess.run(['useradd','--system','--home-dir',str(root),'--shell','/usr/sbin/nologin','circuitstudio-ai'],check=True)
        account=pwd.getpwnam('circuitstudio-ai')
    data=root/'data'; data.mkdir(exist_ok=True);data.chmod(0o700);os.chown(data,account.pw_uid,account.pw_gid)
    service=root/'service';service.mkdir(exist_ok=True)
    for name in ['ai_server.py','ai_agent.py','ai_admin.py','requirements.txt','ai_requirements.txt']:
        target=service/name
        if target.exists(): shutil.copyfile(target,backup/name)
        shutil.copyfile(args.source/name,target); target.chmod(0o644)
    venv=root/'venv'
    if not (venv/'bin/python').exists(): subprocess.run(['python3','-m','venv',str(venv)],check=True)
    subprocess.run([str(venv/'bin/pip'),'install','-r',str(service/'ai_requirements.txt')],check=True)
    environment=Path('/etc/circuitstudio-ai.env')
    if not environment.exists():
        password=secrets.token_urlsafe(24)
        generated=subprocess.run([str(venv/'bin/python'),'-c','import sys;from werkzeug.security import generate_password_hash;print(generate_password_hash(sys.stdin.read()))'],input=password,text=True,check=True,capture_output=True).stdout.strip()
        environment.write_text('CS_AI_DB=/srv/circuitstudio-ai/data/usage.sqlite3\nCS_AI_ADMIN_PASSWORD_HASH='+generated+'\n');environment.chmod(0o600)
        password_file=root/'admin-password.txt';password_file.write_text(password+'\n');password_file.chmod(0o600)
    certificates=root/'apple-roots';certificates.mkdir(exist_ok=True)
    certificate=certificates/'AppleRootCA-G3.cer'
    if not certificate.exists():
        with urllib.request.urlopen('https://www.apple.com/certificateauthority/AppleRootCA-G3.cer',timeout=30,context=ssl.create_default_context()) as response:
            certificate.write_bytes(response.read(20000))
        certificate.chmod(0o644)
    # These are public app identifiers and trust roots; no Apple private key is needed
    # for signed transaction verification and signed Server Notifications V2.
    env_text=environment.read_text()
    for name,value in [('CS_APPLE_APP_ID','6819344214'),('CS_APPLE_ROOT_CERTS',str(certificates)),('CS_APPLE_BUNDLE_ID','com.circuitstudio.app'),('CS_APPLE_ENVIRONMENT','Production')]:
        if not re.search(r'^'+name+r'=',env_text,re.M): env_text += name+'='+value+'\n'
    environment.write_text(env_text);environment.chmod(0o600)
    unit=Path('/etc/systemd/system/circuitstudio-ai.service')
    if unit.exists(): shutil.copyfile(unit,backup/unit.name)
    unit.write_text('''[Unit]
Description=Circuit Studio private DeepSeek relay
After=network.target
[Service]
User=circuitstudio-ai
Group=circuitstudio-ai
WorkingDirectory=/srv/circuitstudio-ai/service
EnvironmentFile=/etc/circuitstudio-ai.env
ExecStart=/srv/circuitstudio-ai/venv/bin/gunicorn --bind 127.0.0.1:5088 --workers 2 --threads 4 --timeout 120 "ai_server:create_app()"
Restart=on-failure
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/srv/circuitstudio-ai/data
[Install]
WantedBy=multi-user.target
''');unit.chmod(0o644)
    subprocess.run(['systemctl','daemon-reload'],check=True)
    subprocess.run(['systemctl','enable','--now','circuitstudio-ai'],check=True)
    subprocess.run(['systemctl','restart','circuitstudio-ai'],check=True)
    for attempt in range(30):
        try:
            with urllib.request.urlopen('http://127.0.0.1:5088/health',timeout=3) as response:
                if response.status==200: break
        except Exception:
            if attempt==29: raise
            time.sleep(.3)
    nginx=Path('/etc/nginx/sites-enabled/homepage').resolve();original=nginx.read_text();shutil.copyfile(nginx,backup/'nginx.conf')
    location='''    # BEGIN CIRCUIT AI
    location ^~ /api/circuit-ai/ {
        client_max_body_size 6m;
        proxy_pass http://127.0.0.1:5088/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Prefix /api/circuit-ai;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
    # END CIRCUIT AI
'''
    if '# BEGIN CIRCUIT AI' in original: updated=re.sub(r'    # BEGIN CIRCUIT AI.*?    # END CIRCUIT AI\n',location,original,flags=re.S)
    else:
        marker='    # BEGIN CIRCUIT STUDIO'
        if original.count(marker)!=1: raise RuntimeError('Cannot identify the HTTPS website server block; configure nginx manually.')
        updated=original.replace(marker,location+'\n'+marker,1)
    nginx.write_text(updated)
    try: subprocess.run(['nginx','-t'],check=True)
    except Exception: nginx.write_text(original);raise
    subprocess.run(['systemctl','reload','nginx'],check=True)
    print('AI relay ready: https://www.weitao-jiang.cn/api/circuit-ai/admin')
    print('Administrator password is stored only in /srv/circuitstudio-ai/admin-password.txt (root-only).')
    print('No DeepSeek key was imported or used. Enter it in the admin page.')

if __name__=='__main__': main()
