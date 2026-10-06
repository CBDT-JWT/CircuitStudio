#!/usr/bin/env python3
"""Build a universal Mac app and a drag-to-Applications DMG without Finder automation."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='1.1.0')
    parser.add_argument('--build', default='4')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--sign-identity', default='-', help='Developer ID Application identity, or - for an ad-hoc build')
    parser.add_argument('--notary-profile', help='Existing notarytool Keychain profile; requires a Developer ID signature')
    args = parser.parse_args()
    try:
        import dmgbuild
    except ImportError:
        parser.error('Install dmgbuild in your Python environment: python3 -m pip install dmgbuild==1.6.7')
    if args.notary_profile and args.sign_identity == '-':
        parser.error('Apple notarization requires a Developer ID Application signing identity.')
    output = ROOT / 'Release/Direct'; output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        log = output / 'build.log'
        print('Building arm64 + x86_64; log:', log, flush=True)
        with log.open('w') as stream:
            run(['xcodebuild', '-project', ROOT / 'CircuitStudio.xcodeproj', '-scheme', 'CircuitStudio', '-configuration', 'Release',
                 '-destination', 'generic/platform=macOS', '-derivedDataPath', ROOT / 'build-direct', 'ARCHS=arm64 x86_64',
                 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO', 'MARKETING_VERSION=' + args.version, 'CURRENT_PROJECT_VERSION=' + args.build, 'build'], stdout=stream, stderr=subprocess.STDOUT)
    source = ROOT / 'build-direct/Build/Products/Release/CircuitStudio.app'
    with tempfile.TemporaryDirectory(prefix='circuitstudio-distribution-') as temporary:
        staging = Path(temporary)
        app = staging / 'Circuit Studio.app'
        run(['ditto', '--norsrc', source, app])
        signing = ['codesign', '--force', '--deep', '--sign', args.sign_identity, '--options', 'runtime', '--entitlements', ROOT / 'Resources/CircuitStudio.macOS.entitlements']
        signing += ['--timestamp=none'] if args.sign_identity == '-' else ['--timestamp']
        run(signing + [app])
        run(['codesign', '--verify', '--deep', '--strict', app])
        binary = app / 'Contents/MacOS/CircuitStudio'
        architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise RuntimeError('Expected a universal arm64 + x86_64 executable')
        background = staging / 'background.png'
        run(['swift', ROOT / 'scripts/make_dmg_background.swift', background])
        readme = staging / 'Read Me.txt'
        readme.write_text('Circuit Studio ' + args.version + '\n\nDrag Circuit Studio.app into Applications.\nRequires macOS 26 or later. Supports Apple Silicon and Intel.\n\n' +
            ('This build is not notarized by Apple. After attempting to open it, use System Settings > Privacy & Security > Open Anyway if macOS blocks the app.\nhttps://support.apple.com/102445\n\n' if not args.notary_profile else '') +
            'Schematic: circuit drawing with offline ngspice simulation.\nIllustration: block diagrams, ports and paper figures, without simulation.\n\nSource: https://github.com/CBDT-JWT/CircuitStudio\nApp source: MIT. ngspice keeps its own license, included in the app.\n', encoding='utf-8')
        dmg = output / ('CircuitStudio-' + args.version + '-universal.dmg')
        if dmg.exists():
            dmg.unlink()
        dmgbuild.build_dmg(str(dmg), 'Circuit Studio', settings={
            'files': [str(app), str(readme)], 'symlinks': {'Applications': '/Applications'},
            'icon_locations': {'Circuit Studio.app': (170, 200), 'Applications': (470, 200), 'Read Me.txt': (560, 345)},
            'window_rect': ((160, 160), (640, 400)), 'icon_size': 90, 'text_size': 13,
            'background': str(background), 'format': 'UDZO', 'filesystem': 'APFS', 'compression_level': 9,
            'default_view': 'icon-view', 'show_toolbar': False, 'show_sidebar': False,
            'show_status_bar': False, 'show_pathbar': False,
        })
        if args.notary_profile:
            run(['xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile, '--wait'])
            run(['xcrun', 'stapler', 'staple', dmg])
            run(['xcrun', 'stapler', 'validate', dmg])
        run(['hdiutil', 'verify', dmg])
        # Verify the delivered app, after disk-image tools have written Finder metadata.
        mount = staging / 'mounted'; mount.mkdir()
        attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', '-mountpoint', str(mount), str(dmg)]))
        device = attached['system-entities'][0]['dev-entry']
        try:
            delivered = mount / app.name
            run(['codesign', '--verify', '--deep', '--strict', delivered])
            delivered_architectures = subprocess.check_output(['lipo', '-archs', str(delivered / 'Contents/MacOS/CircuitStudio')], text=True).split()
            if set(delivered_architectures) != set(architectures):
                raise RuntimeError('The disk image does not contain the expected universal app')
            info = plistlib.loads((delivered / 'Contents/Info.plist').read_bytes())
            if info['CFBundleShortVersionString'] != args.version or info['CFBundleVersion'] != args.build:
                raise RuntimeError('The disk image version does not match the requested release')
            if not (mount / 'Applications').is_symlink() or not (mount / '.background.png').is_file():
                raise RuntimeError('The drag-to-install layout is incomplete')
        finally:
            run(['hdiutil', 'detach', device])
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (output / 'SHA256SUMS.txt').write_text(digest + '  ' + dmg.name + '\n')
        (output / 'release.json').write_text(json.dumps({'version': args.version, 'build': args.build, 'file': dmg.name, 'bytes': dmg.stat().st_size,
            'sha256': digest, 'architectures': architectures, 'minimumMacOS': '26.0', 'signature': 'ad-hoc' if args.sign_identity == '-' else 'Developer ID',
            'notarized': bool(args.notary_profile)}, indent=2) + '\n')
        print('Created:', dmg)
        print('SHA256:', digest)

if __name__ == '__main__':
    main()
