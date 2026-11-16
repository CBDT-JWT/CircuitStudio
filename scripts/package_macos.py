#!/usr/bin/env python3
"""Build a universal Mac app and a drag-to-Applications DMG without Finder automation."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)

def embed_codex_bridge(app, staging, signing):
    helper = app / 'Contents/XPCServices/CodexBridge.xpc'
    contents = helper / 'Contents'
    binary = contents / 'MacOS/CodexBridge'
    binary.parent.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'Helpers/CodexBridge/main.swift'
    protocol = ROOT / 'Sources/CircuitStudio/LocalCodexIPC.swift'
    slices = []
    for architecture in ['arm64', 'x86_64']:
        thin = staging / ('CodexBridge-' + architecture)
        run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-target', architecture + '-apple-macos26.0',
             '-module-cache-path', staging / 'codex-module-cache', source, protocol, '-o', thin])
        slices.append(thin)
    run(['lipo', '-create', *slices, '-output', binary])
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.circuitstudio.app.CodexBridge',
        'CFBundleExecutable': 'CodexBridge',
        'CFBundleName': 'Circuit Studio Codex Bridge',
        'CFBundlePackageType': 'XPC!',
        'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': '1',
        'XPCService': {'ServiceType': 'Application'},
    }))
    run(signing + [helper])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='1.2.0')
    parser.add_argument('--build', default='5')
    parser.add_argument('--work-dir', type=Path, help='Build/cache storage, preferably an external APFS volume')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--sign-identity', default='auto', help='Existing Developer ID or Apple Development identity; auto prefers Developer ID')
    parser.add_argument('--notary-profile', help='Existing notarytool Keychain profile; requires a Developer ID signature')
    args = parser.parse_args()
    try:
        import dmgbuild
    except ImportError:
        parser.error('Install dmgbuild in your Python environment: python3 -m pip install dmgbuild==1.6.7')
    if args.sign_identity == 'auto':
        identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        import re
        available = re.findall(r'([A-F0-9]{40}) "([^"]+)"', identities)
        candidates = [item for item in available if item[1].startswith('Developer ID Application:')]
        candidates += [item for item in available if item[1].startswith('Apple Development:')]
        if not candidates:
            parser.error('Sparkle requires an existing Apple signing identity for Hardened Runtime library validation.')
        args.sign_identity, signing_name = candidates[0]
    else:
        signing_name = args.sign_identity
    if args.sign_identity == '-':
        parser.error('Use an Apple signing identity for the Sparkle-enabled direct build.')
    if args.notary_profile and 'Developer ID' not in signing_name:
        parser.error('Apple notarization requires a Developer ID Application signing identity.')
    work = (args.work_dir or ROOT / 'build-direct-work').resolve(); work.mkdir(parents=True,exist_ok=True)
    output = work / 'Output' if args.work_dir else ROOT / 'Release/Direct'; output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        log = output / 'build.log'
        print('Building arm64 + x86_64; log:', log, flush=True)
        # iCloud-managed source directories can suspend Xcode's coordinated reads.
        with tempfile.TemporaryDirectory(prefix='circuitstudio-build-source-',dir=work) as checkout:
            checkout = Path(checkout)
            for name in ['Sources', 'Resources', 'Vendor', 'CircuitStudio.xcodeproj']:
                source_tree = ROOT / name
                for file in source_tree.rglob('*'):
                    if file.is_file() and file.stat().st_flags & 0x40000000:
                        run(['brctl', 'download', file], stdout=subprocess.DEVNULL)
                shutil.copytree(source_tree, checkout / name, symlinks=True, ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate'))
            (checkout / 'Release').mkdir()
            shutil.copy2(ROOT / 'Release/Release.xcconfig', checkout / 'Release/Release.xcconfig')
            shutil.copy2(ROOT / 'LICENSE', checkout / 'LICENSE')
            with log.open('w') as stream:
                run(['xcodebuild', '-project', checkout / 'CircuitStudio.xcodeproj', '-scheme', 'CircuitStudio', '-configuration', 'Release',
                 '-destination', 'generic/platform=macOS', '-derivedDataPath', work / 'DerivedData', 'ARCHS=arm64 x86_64',
                 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO', 'MARKETING_VERSION=' + args.version, 'CURRENT_PROJECT_VERSION=' + args.build, 'build'], stdout=stream, stderr=subprocess.STDOUT)
    source = work / 'DerivedData/Build/Products/Release/CircuitStudio.app'
    with tempfile.TemporaryDirectory(prefix='circuitstudio-distribution-',dir=work) as temporary:
        staging = Path(temporary)
        app = staging / 'Circuit Studio.app'
        run(['ditto', '--norsrc', source, app])
        framework = app / 'Contents/Frameworks/Sparkle.framework'
        common_signing = ['codesign', '--force', '--sign', args.sign_identity, '--options', 'runtime', '--timestamp']
        for helper in ['XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc', 'Autoupdate', 'Updater.app']:
            extra = ['--preserve-metadata=entitlements'] if helper.endswith('Downloader.xpc') else []
            run(common_signing + extra + [framework / 'Versions/B' / helper])
        run(common_signing + [framework])
        embed_codex_bridge(app, staging, common_signing)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        entitlements = staging / 'direct.entitlements'
        entitlements.write_text((ROOT / 'Resources/CircuitStudio.Direct.entitlements').read_text().replace('$(PRODUCT_BUNDLE_IDENTIFIER)', info['CFBundleIdentifier']))
        run(common_signing + ['--entitlements', entitlements, app])
        run(['codesign', '--verify', '--deep', '--strict', app])
        binary = app / 'Contents/MacOS/CircuitStudio'
        architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise RuntimeError('Expected a universal arm64 + x86_64 executable')
        background = staging / 'background.png'
        run(['swift', ROOT / 'scripts/make_dmg_background.swift', background])
        readme = staging / 'Read Me.txt'
        readme.write_text('Circuit Studio ' + args.version + '\n\nDrag Circuit Studio.app into Applications.\nRequires macOS 26 or later. Supports Apple Silicon and Intel.\n\n' +
            ('This build is signed but is not notarized by Apple. macOS Gatekeeper may prevent it from opening.\n\n' if not args.notary_profile else '') +
            'Schematic: circuit drawing with offline ngspice simulation.\nIllustration: block diagrams, ports and paper figures, without simulation.\n\nSource: https://github.com/CBDT-JWT/CircuitStudio\nApp source: MIT. Bundled vector artwork, ngspice, fonts and other dependencies retain their separate licenses, included in the app.\n', encoding='utf-8')
        dmg = staging / ('CircuitStudio-' + args.version + '-universal.dmg')
        dmgbuild.build_dmg(str(dmg), 'Circuit Studio', settings={
            'files': [str(app), str(readme)], 'symlinks': {'Applications': '/Applications'},
            'icon_locations': {'Circuit Studio.app': (170, 200), 'Applications': (470, 200), 'Read Me.txt': (560, 345)},
            'window_rect': ((160, 160), (640, 400)), 'icon_size': 90, 'text_size': 13,
            'background': str(background), 'format': 'UDZO', 'filesystem': 'HFS+', 'compression_level': 9,
            'default_view': 'icon-view', 'show_toolbar': False, 'show_sidebar': False,
            'show_status_bar': False, 'show_pathbar': False,
        })
        run(common_signing + [dmg])
        if args.notary_profile:
            run(['xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile, '--wait'])
            run(['xcrun', 'stapler', 'staple', dmg])
            run(['xcrun', 'stapler', 'validate', dmg])
        run(['codesign','--verify','--strict',dmg])
        run(['hdiutil', 'verify', dmg])
        # Verify the delivered app, after disk-image tools have written Finder metadata.
        attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(dmg)]))
        volume = next(entity for entity in attached['system-entities'] if entity.get('mount-point'))
        mount = Path(volume['mount-point']); device = volume['dev-entry']
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
        delivered_image = output / dmg.name
        pending_image = output / ('.' + dmg.name + '.new')
        shutil.copyfile(dmg, pending_image)
        os.replace(pending_image, delivered_image)
        (output / 'SHA256SUMS.txt').write_text(digest + '  ' + dmg.name + '\n')
        (output / 'release.json').write_text(json.dumps({'version': args.version, 'build': args.build, 'file': dmg.name, 'bytes': dmg.stat().st_size,
            'sha256': digest, 'architectures': architectures, 'minimumMacOS': '26.0', 'signature': 'Developer ID' if 'Developer ID' in signing_name else 'Apple Development',
            'notarized': bool(args.notary_profile)}, indent=2) + '\n')
        print('Created:', delivered_image)
        print('SHA256:', digest)

if __name__ == '__main__':
    main()
