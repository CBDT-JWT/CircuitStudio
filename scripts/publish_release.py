#!/usr/bin/env python3
"""Build, sign, publish and deploy a Mac update from one local command."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from deploy_server import deploy
from sparkle_tools import ACCOUNT, tools_directory

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def output(command):
    return subprocess.check_output(list(map(str, command)), text=True).strip()


def main():
    configuration = (ROOT / 'Release/Release.xcconfig').read_text()
    default_version = re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', configuration, re.M)[1]
    default_build = re.search(r'^CURRENT_PROJECT_VERSION\s*=\s*(\d+)', configuration, re.M)[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default=default_version)
    parser.add_argument('--build', default=default_build)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--host', default='root@www.weitao-jiang.cn')
    parser.add_argument('--repo', default='CBDT-JWT/CircuitStudio')
    parser.add_argument('--sign-identity', default='auto')
    parser.add_argument('--notary-profile')
    parser.add_argument('--skip-build', action='store_true', help='Reuse a verified local DMG')
    parser.add_argument('--resume', action='store_true', help='Resume this version while its GitHub release is still a draft')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', args.version) or not re.fullmatch(r'[1-9]\d*', args.build):
        parser.error('Use a semantic version and an increasing numeric build number.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo): parser.error('Invalid GitHub repository')
    if args.host.startswith('-') or not re.fullmatch(r'[A-Za-z0-9_.@:-]+', args.host): parser.error('Invalid SSH host')
    if output(['git', 'status', '--porcelain']):
        parser.error('Commit the source changes first so the release tag identifies exactly what was built.')
    notes = args.notes or ROOT / f'docs/release-{args.version}.md'
    if not notes.is_file(): parser.error('Provide release notes with --notes PATH.')
    tools = tools_directory()
    public_key = output([tools / 'generate_keys', '--account', ACCOUNT, '-p'])
    trusted_key = plistlib.loads((ROOT / 'Resources/Info.Direct.plist').read_bytes())['SUPublicEDKey']
    if public_key != trusted_key:
        parser.error('The local Keychain signing key does not match the key trusted by installed apps.')
    tag = 'v' + args.version
    prior = subprocess.run(['gh', 'release', 'view', tag, '--repo', args.repo, '--json', 'isDraft,targetCommitish'], capture_output=True, text=True)
    if prior.returncode == 0:
        if not args.resume or not json.loads(prior.stdout)['isDraft']:
            parser.error('This version already exists. Increase the version/build, or resume its existing draft.')
    elif args.resume:
        parser.error('There is no draft release for this version to resume.')
    if args.resume and output(['git', 'rev-list', '-n', '1', tag]) != output(['git', 'rev-parse', 'HEAD']):
        parser.error('The draft tag must identify the current source commit before resuming.')
    # Sparkle orders updates by CFBundleVersion, independently of the display version.
    latest = json.loads(output(['gh', 'release', 'view', '--repo', args.repo, '--json', 'tagName']))['tagName']
    with tempfile.TemporaryDirectory(prefix='circuitstudio-prior-release-') as temporary:
        run(['gh', 'release', 'download', latest, '--repo', args.repo, '--pattern', 'release.json', '--dir', temporary])
        latest_metadata = json.loads((Path(temporary) / 'release.json').read_text())
    if int(args.build) <= int(latest_metadata['build']):
        parser.error('Increase CURRENT_PROJECT_VERSION above the latest published build before publishing.')
    directory = ROOT / 'Release/Direct'
    if not args.skip_build:
        environment = Path.home() / 'Library/Caches/CircuitStudio/packaging'
        python = environment / 'bin/python'
        if not python.exists(): run([sys.executable, '-m', 'venv', environment])
        installed = subprocess.run([python, '-c', 'import dmgbuild'], capture_output=True).returncode == 0
        if not installed: run([environment / 'bin/pip', 'install', 'dmgbuild==1.6.7'])
        command = [python, ROOT / 'scripts/package_macos.py', '--version', args.version, '--build', args.build, '--sign-identity', args.sign_identity]
        if args.notary_profile: command += ['--notary-profile', args.notary_profile]
        run(command)
    metadata = json.loads((directory / 'release.json').read_text())
    if metadata['version'] != args.version or metadata['build'] != args.build:
        parser.error('The local DMG does not match this version and build.')
    import hashlib
    archive = directory / metadata['file']
    if hashlib.sha256(archive.read_bytes()).hexdigest() != metadata['sha256']:
        parser.error('The local archive checksum does not match its release metadata.')
    updates = ROOT / 'Release/Updates'; updates.mkdir(parents=True, exist_ok=True)
    shutil.copy2(archive, updates / archive.name)
    shutil.copy2(notes, updates / (archive.stem + '.md'))
    run([tools / 'generate_appcast', '--account', ACCOUNT, '--download-url-prefix', f'https://github.com/{args.repo}/releases/download/{tag}/',
         '--link', 'https://www.weitao-jiang.cn/static/circuit-studio/', '--versions', args.build,
         '--maximum-deltas', '0', '--maximum-versions', '3', '--embed-release-notes', '-o', updates / 'appcast.xml', updates])
    run([tools / 'sign_update', '--account', ACCOUNT, '--verify', updates / 'appcast.xml'])
    import xml.etree.ElementTree as ET
    ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    feed = ET.parse(updates / 'appcast.xml')
    item = next(item for item in feed.findall('./channel/item') if item.findtext('sparkle:version', namespaces=ns) == args.build)
    enclosure = item.find('enclosure')
    if enclosure.get('url') != f'https://github.com/{args.repo}/releases/download/{tag}/{archive.name}':
        raise RuntimeError('The appcast installer URL does not match this release')
    run([tools / 'sign_update', '--account', ACCOUNT, '--verify', archive, enclosure.get('{' + ns['sparkle'] + '}edSignature')])
    commit = output(['git', 'rev-parse', 'HEAD'])
    branch = output(['git', 'branch', '--show-current'])
    if not branch: parser.error('Publish from a named branch.')
    run(['git', 'push', 'origin', branch])
    if prior.returncode != 0:
        if subprocess.run(['git', 'rev-parse', '--verify', 'refs/tags/' + tag], capture_output=True).returncode == 0:
            if output(['git', 'rev-list', '-n', '1', tag]) != commit:
                parser.error('The existing tag points to a different source commit.')
        else:
            run(['git', 'tag', '-a', tag, '-m', 'Circuit Studio ' + args.version])
        run(['git', 'push', 'origin', tag])
        run(['gh', 'release', 'create', tag, '--repo', args.repo, '--draft', '--verify-tag', '--title', 'Circuit Studio ' + args.version + ' · Universal Mac', '--notes-file', notes])
    run(['gh', 'release', 'upload', tag, archive, directory / 'SHA256SUMS.txt', directory / 'release.json', updates / 'appcast.xml', '--repo', args.repo, '--clobber'])
    deploy(directory, args.host)
    run(['gh', 'release', 'edit', tag, '--repo', args.repo, '--draft=false', '--latest'])
    print('Published:', f'https://github.com/{args.repo}/releases/tag/{tag}')
    print('Website:', 'https://www.weitao-jiang.cn/static/circuit-studio/')
    print('Installed users can now check for this signed update from the app.')

if __name__ == '__main__':
    main()
