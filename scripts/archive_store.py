#!/usr/bin/env python3
"""Archive native Mac and universal iPhone/iPad builds; export or upload explicitly."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--platform', choices=['mac', 'mobile', 'both'], default='both')
parser.add_argument('--team', help='Apple Developer Team ID')
parser.add_argument('--bundle-id', default='com.circuitstudio.app')
parser.add_argument('--version', default='1.0.0')
parser.add_argument('--build', default='1')
parser.add_argument('--unsigned', action='store_true', help='Local readiness check only; cannot upload')
parser.add_argument('--use-existing', action='store_true', help='Verify and distribute an existing archive without rebuilding')
parser.add_argument('--work-dir', type=Path, default=Path.home() / 'Library/Caches/CircuitStudioDistribution',
                    help='Local build storage outside iCloud/File Provider directories')
action = parser.add_mutually_exclusive_group()
action.add_argument('--export', action='store_true')
action.add_argument('--upload', action='store_true')
args = parser.parse_args()
if args.unsigned and (args.export or args.upload):
    parser.error('Unsigned archives cannot be exported for App Store distribution or uploaded.')
if not args.unsigned and (not args.team or not re.fullmatch(r'[A-Z0-9]{10}', args.team)):
    parser.error('A verified Apple Developer Team ID is required for signing.')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
    parser.error('Invalid bundle identifier.')
if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', args.version) or not re.fullmatch(r'\d+', args.build):
    parser.error('Use a numeric marketing version and build number.')
release = ROOT / 'Release'
work = args.work_dir.resolve()
archives = work / 'Archives'; archives.mkdir(parents=True, exist_ok=True)
exports = work / 'Exports'; exports.mkdir(parents=True, exist_ok=True)
variants = [('mac', 'CircuitStudioMac', 'generic/platform=macOS', 'macOS'),
            ('mobile', 'CircuitStudioMobile', 'generic/platform=iOS', 'iOS')]
if args.platform != 'both':
    variants = [variant for variant in variants if variant[0] == args.platform]
for key, scheme, destination, label in variants:
    archive = archives / (label + '.xcarchive')
    log = release / (label + '-archive.log')
    command = ['xcodebuild', '-project', str(ROOT / 'CircuitStudio.xcodeproj'), '-scheme', scheme,
               '-configuration', 'Release', '-destination', destination,
               '-derivedDataPath', str(work / 'Build' / key), '-archivePath', str(archive),
               'MARKETING_VERSION=' + args.version, 'CURRENT_PROJECT_VERSION=' + args.build,
               'PRODUCT_BUNDLE_IDENTIFIER=' + args.bundle_id]
    command += ['CODE_SIGNING_ALLOWED=NO'] if args.unsigned else ['DEVELOPMENT_TEAM=' + args.team, '-allowProvisioningUpdates']
    if not args.use_existing:
        print(f'Archiving {label} ({"unsigned local check" if args.unsigned else "signed"})…', flush=True)
        with log.open('w') as output:
            result = subprocess.run(command + ['archive'], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text()[-12000:]); raise SystemExit(result.returncode)
    info = plistlib.loads((archive / 'Info.plist').read_bytes())
    app = archive / 'Products' / info['ApplicationProperties']['ApplicationPath']
    resource = app / 'Contents/Resources' if key == 'mac' else app
    bundle_info = app / 'Contents/Info.plist' if key == 'mac' else app / 'Info.plist'
    app_info = plistlib.loads(bundle_info.read_bytes())
    privacy = plistlib.loads((resource / 'PrivacyInfo.xcprivacy').read_bytes())
    assert app_info['CFBundleIdentifier'] == args.bundle_id
    assert app_info['CFBundleShortVersionString'] == args.version
    assert app_info['CFBundleVersion'] == args.build
    assert privacy['NSPrivacyTracking'] is False
    assert (resource / 'ngspice-COPYING.txt').is_file()
    if not args.unsigned:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    status = {'platform': label, 'archive': str(archive),
              'bundleID': args.bundle_id, 'version': args.version, 'build': args.build,
              'signed': not args.unsigned, 'exported': False, 'uploaded': False,
              'privacyManifestPresent': True, 'thirdPartyLicensePresent': True}
    status_path = release / (label + '-archive-status.json')
    status_path.write_text(json.dumps(status, indent=2) + '\n')
    if args.export or args.upload:
        options = {'method': 'app-store-connect', 'signingStyle': 'automatic', 'teamID': args.team,
                   'destination': 'upload' if args.upload else 'export',
                   'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True,
                   'stripSwiftSymbols': True}
        options_path = exports / (label + '-ExportOptions.plist')
        options_path.write_bytes(plistlib.dumps(options))
        command = ['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                   '-exportOptionsPlist', str(options_path), '-exportPath', str(exports / label),
                   '-allowProvisioningUpdates']
        export_log = release / (label + '-distribution.log')
        with export_log.open('w') as output:
            result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(export_log.read_text()[-12000:]); raise SystemExit(result.returncode)
        status['uploaded' if args.upload else 'exported'] = True
    status_path.write_text(json.dumps(status, indent=2) + '\n')
    print(f'{label}: archive verified. Uploaded: {status["uploaded"]}.', flush=True)
