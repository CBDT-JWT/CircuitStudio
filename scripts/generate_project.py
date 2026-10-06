#!/usr/bin/env python3
"""Generate shared development and dedicated App Store targets."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quote(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, content):
    key = ident(name); objects.append(f'{key} = {{ {content} }};'); return key
def settings_text(settings):
    return ' '.join(quote(key) + ' = ' + quote(value) + ';' for key, value in settings.items())
source_refs = []
for file in sorted(root.glob('Sources/**/*.swift')):
    relative = file.relative_to(root).as_posix()
    source_refs.append(obj('ref:' + relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;'))
resources = []
for name, file_type, path in [
    ('assets', 'folder.assetcatalog', 'Resources/Assets.xcassets'),
    ('license', 'text', 'Resources/ngspice-COPYING.txt'),
    ('privacy', 'text.xml', 'Resources/PrivacyInfo.xcprivacy'),
    ('sparkle-license', 'text', 'Resources/Sparkle-LICENSE.txt'),
    ('application-license', 'text', 'LICENSE'),
]:
    resources.append(obj(name, f'isa = PBXFileReference; lastKnownFileType = {file_type}; path = {quote(path)}; sourceTree = SOURCE_ROOT;'))
spice = obj('spice', 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Vendor/ngspice/NgSpice.xcframework; sourceTree = SOURCE_ROOT;')
sparkle = obj('sparkle', 'isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = Vendor/Sparkle/Sparkle.framework; sourceTree = SOURCE_ROOT;')
release_config = obj('release-config', 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Release/Release.xcconfig; sourceTree = SOURCE_ROOT;')
entitlement = obj('entitlements', 'isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Resources/CircuitStudio.macOS.entitlements; sourceTree = SOURCE_ROOT;')
base = {
    'PRODUCT_NAME': 'CircuitStudio',
    'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete',
    'MACOSX_DEPLOYMENT_TARGET': '26.0', 'IPHONEOS_DEPLOYMENT_TARGET': '26.0',
    'SUPPORTS_MACCATALYST': 'NO', 'TARGETED_DEVICE_FAMILY': '1,2',
    'INFOPLIST_FILE': 'Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
    'CODE_SIGN_STYLE': 'Automatic',
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'CLANG_ENABLE_MODULES': 'YES',
    'SWIFT_EMIT_LOC_STRINGS': 'YES', 'ENABLE_HARDENED_RUNTIME': 'YES',
    'OTHER_LDFLAGS': '$(inherited) -lc++',
    'FRAMEWORK_SEARCH_PATHS[sdk=macosx*]': '$(inherited) $(SRCROOT)/Vendor/Sparkle',
    'LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]': '$(inherited) @executable_path/../Frameworks',
    'ENABLE_APP_SANDBOX[sdk=macosx*]': 'YES',
    'CODE_SIGN_ENTITLEMENTS[sdk=macosx*]': 'Resources/CircuitStudio.macOS.entitlements',
    'ENABLE_USER_SELECTED_FILES': 'readwrite', 'DEAD_CODE_STRIPPING': 'YES',
}
targets, products, schemes = [], [], []
for name, sdk, platforms, is_store in [
    ('CircuitStudio', 'auto', 'macosx iphoneos iphonesimulator', False),
    ('CircuitStudioMac', 'macosx', 'macosx', True),
    ('CircuitStudioMobile', 'iphoneos', 'iphoneos iphonesimulator', True),
]:
    product = obj(name + ':product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = CircuitStudio.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    def phase(kind, refs):
        builds = [obj(f'{name}:{kind}:{ref}', f'isa = PBXBuildFile; fileRef = {ref};' + (' platformFilter = macos;' if ref == sparkle else '')) for ref in refs]
        return obj(f'{name}:{kind}', f'isa = PBX{kind}BuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
    phases = [phase('Sources', source_refs), phase('Frameworks', [spice] + ([sparkle] if not is_store else [])), phase('Resources', resources)]
    if not is_store:
        embedded = obj(name + ':embed-sparkle', f'isa = PBXBuildFile; fileRef = {sparkle}; platformFilter = macos; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy);}};')
        phases.append(obj(name + ':embed-frameworks', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = ({embedded}); runOnlyForDeploymentPostprocessing = 0;'))
    configs = []
    for config in ['Debug', 'Release']:
        settings = base | {
            'SDKROOT': sdk, 'SUPPORTED_PLATFORMS': platforms,
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
            'SWIFT_COMPILATION_MODE': 'incremental' if config == 'Debug' else 'wholemodule',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': ('DEBUG ' if config == 'Debug' else '') + ('APP_STORE' if is_store else ''),
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym',
            'SKIP_INSTALL': 'NO',
        }
        if not is_store:
            settings['INFOPLIST_FILE[sdk=macosx*]'] = 'Resources/Info.Direct.plist'
            settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'Resources/CircuitStudio.Direct.entitlements'
        configs.append(obj(f'{name}:config:{config}', f'isa = XCBuildConfiguration; baseConfigurationReference = {release_config}; buildSettings = {{{settings_text(settings)}}}; name = {config};'))
    cl = obj(name + ':configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    target = obj(name + ':target', f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({",".join(phases)}); buildRules = (); dependencies = (); name = {name}; productName = CircuitStudio; productReference = {product}; productType = "com.apple.product-type.application";')
    targets.append(target); schemes.append((name, target))
products_group = obj('products', f'isa = PBXGroup; children = ({",".join(products)}); name = Products; sourceTree = "<group>";')
group = obj('main', f'isa = PBXGroup; children = ({",".join(source_refs + resources + [spice, sparkle, release_config, entitlement, products_group])}); sourceTree = "<group>";')
pconfigs = [obj('project:' + name, f'isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES;}}; name = {name};') for name in ['Debug', 'Release']]
pcl = obj('project:configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(pconfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = obj('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; BuildIndependentTargetsInParallel = YES;}}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(targets)});')
directory = root / 'CircuitStudio.xcodeproj'; directory.mkdir(exist_ok=True)
(directory / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project}; }}\n')
schemedir = directory / 'xcshareddata/xcschemes'; schemedir.mkdir(parents=True, exist_ok=True)
for name, target in schemes:
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="CircuitStudio.app" BlueprintName="{name}" ReferencedContainer="container:CircuitStudio.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemedir / (name + '.xcscheme')).write_text(scheme)
print(f'Generated {len(schemes)} schemes from {len(source_refs)} shared Swift sources.')
