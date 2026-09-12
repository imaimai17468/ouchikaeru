"""Generate a dependency-free Xcode project. Run from the repository root."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def add(key, isa, **fields):
    ident = uid(key)
    objects[ident] = dict(isa=isa, **fields)
    return ident

def configurations(key, settings):
    configs = []
    for name in ['Debug', 'Release']:
        values = dict(settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if name == 'Debug' else '-O'
        if name == 'Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        configs.append(add(key+name, 'XCBuildConfiguration', buildSettings=values, name=name))
    return add(key+'configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

core = sorted((ROOT/'Sources/TransitCore').glob('*.swift'))
shared = ROOT/'Shared'
specs = {
    'Ouchikaeru': (core + sorted((ROOT/'iPhone').glob('*.swift')) + sorted(shared.glob('*.swift')), 'iphoneos', 'jp.ouchikaeru.app', 'application', 'iPhone'),
    'OuchikaeruWidget': (core + [shared/'RouteViews.swift', shared/'SharedStore.swift'] + sorted((ROOT/'Widget').glob('*.swift')), 'iphoneos', 'jp.ouchikaeru.app.widget', 'app-extension', 'Widget'),
    'OuchikaeruWatch': (core + sorted(shared.glob('*.swift')) + sorted((ROOT/'Watch').glob('*.swift')), 'watchos', 'jp.ouchikaeru.app.watchkitapp', 'application', 'Watch'),
}
refs = {}
for files, *_ in specs.values():
    for file in files:
        path = str(file.relative_to(ROOT))
        if path not in refs: refs[path] = add(path, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path, sourceTree='<group>')
asset_catalog = ROOT/'Assets.xcassets'
asset_ref = add('Assets.xcassets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>') if asset_catalog.exists() else None
products = []
for name, (files, sdk, bundle, kind, folder) in specs.items():
    ext = 'appex' if kind == 'app-extension' else 'app'
    product = add(name+'product', 'PBXFileReference', explicitFileType='wrapper.app-extension' if ext == 'appex' else 'wrapper.application', includeInIndex=0, path=name+'.'+ext, sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    sources = add(name+'sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[add(name+str(f), 'PBXBuildFile', fileRef=refs[str(f.relative_to(ROOT))]) for f in files], runOnlyForDeploymentPostprocessing=0)
    resource_files = [add(name+'assets', 'PBXBuildFile', fileRef=asset_ref)] if name == 'Ouchikaeru' and asset_ref else []
    resources = add(name+'resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resource_files,runOnlyForDeploymentPostprocessing=0)
    settings = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle, PRODUCT_NAME='$(TARGET_NAME)', SDKROOT=sdk, SWIFT_VERSION='5.0', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='Config/'+folder+'-Info.plist', CODE_SIGN_STYLE='Automatic', TARGETED_DEVICE_FAMILY='4' if sdk == 'watchos' else '1', SKIP_INSTALL='NO' if name == 'Ouchikaeru' else 'YES', SWIFT_EMIT_LOC_STRINGS='YES')
    settings['WATCHOS_DEPLOYMENT_TARGET' if sdk == 'watchos' else 'IPHONEOS_DEPLOYMENT_TARGET'] = '10.0' if sdk == 'watchos' else '17.0'
    settings['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator' if sdk == 'watchos' else 'iphoneos iphonesimulator'
    if sdk == 'iphoneos': settings['CODE_SIGN_ENTITLEMENTS'] = 'Config/AppGroup.entitlements'
    if name == 'Ouchikaeru': settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    if kind == 'app-extension': settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
    add(name, 'PBXNativeTarget', buildConfigurationList=configurations(name,settings), buildPhases=[sources,resources], buildRules=[], dependencies=[], name=name, productName=name, productReference=product, productType='com.apple.product-type.'+kind)
    info = dict(CFBundleDisplayName='オウチカエル', CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0', CFBundleName='$(PRODUCT_NAME)', CFBundlePackageType='XPC!' if kind == 'app-extension' else 'APPL', CFBundleShortVersionString='1.0', CFBundleVersion='1')
    if name == 'Ouchikaeru':
        info.update(NSLocationWhenInUseUsageDescription='現在地から登録した目的地までの経路を検索するため、現在地を交通経路APIへ送信します。', UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'], CFBundleURLTypes=[dict(CFBundleURLName=bundle,CFBundleURLSchemes=['ouchikaeru'])])
    elif name == 'OuchikaeruWidget': info['NSExtension'] = dict(NSExtensionPointIdentifier='com.apple.widgetkit-extension')
    else: info.update(WKApplication=True, WKCompanionAppBundleIdentifier='jp.ouchikaeru.app', WKRunsIndependentlyOfCompanionApp=False, NSLocationWhenInUseUsageDescription='現在地から登録した目的地までの経路を検索するため、現在地を交通経路APIへ送信します。')
    (ROOT/'Config'/f'{folder}-Info.plist').write_bytes(plistlib.dumps(info))

for child, dst, path in [('OuchikaeruWidget',13,''),('OuchikaeruWatch',16,'$(CONTENTS_FOLDER_PATH)/Watch')]:
    proxy = add(child+'proxy','PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=uid(child),remoteInfo=child)
    dep = add(child+'dependency','PBXTargetDependency',target=uid(child),targetProxy=proxy)
    build = add(child+'embed','PBXBuildFile',fileRef=uid(child+'product'),settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
    phase = add(child+'copy','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath=path,dstSubfolderSpec=dst,files=[build],name='Embed '+child,runOnlyForDeploymentPostprocessing=0)
    objects[uid('Ouchikaeru')]['dependencies'].append(dep)
    objects[uid('Ouchikaeru')]['buildPhases'].append(phase)

product_group = add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main_group = add('main','PBXGroup',children=list(refs.values())+([asset_ref] if asset_ref else [])+[product_group],sourceTree='<group>')
add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600'},buildConfigurationList=configurations('project',{'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0'}),compatibilityVersion='Xcode 14.0',developmentRegion='ja',hasScannedForEncodings=0,knownRegions=['ja','en','Base'],mainGroup=main_group,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=[uid(n) for n in specs])
def encode(v):
    if isinstance(v,dict): return '{\n'+'\n'.join(f'{encode(k)} = {encode(val)};' for k,val in v.items())+'\n}'
    if isinstance(v,list): return '('+','.join(encode(x) for x in v)+')'
    if isinstance(v,int): return str(v)
    return json.dumps(v,ensure_ascii=False)
project={'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':uid('project')}
(ROOT/'Ouchikaeru.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(project)+'\n')
(ROOT/'Config/AppGroup.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':['group.jp.ouchikaeru.app']}))
schemes=ROOT/'Ouchikaeru.xcodeproj/xcshareddata/xcschemes'
schemes.mkdir(parents=True,exist_ok=True)
for name in specs:
    ext = 'appex' if name == 'OuchikaeruWidget' else 'app'
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Ouchikaeru.xcodeproj"/>'
    launcher = 'Xcode.IDEFoundation.Launcher.LLDB' if name == 'Ouchikaeru' else 'Xcode.DebuggerFoundation.Launcher.LLDB'
    debug_service = '' if name == 'Ouchikaeru' else ' debugServiceExtension="internal"'
    location = '<LocationScenarioReference identifier="../../../Config/TokyoStation.gpx" referenceType="0"/>' if name == 'Ouchikaeru' else ''
    scheme_path = schemes/f'{name}.xcscheme'
    scheme_path.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" shouldAutocreateTestPlan="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="{launcher}" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"{debug_service} allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable>{location}</LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
    tree = ET.parse(scheme_path)
    ET.indent(tree, space='   ')
    tree.write(scheme_path, encoding='UTF-8', xml_declaration=True)
print('Generated Ouchikaeru.xcodeproj')
if (ROOT/'UITests/RouteFlowTests.swift').exists():
    import subprocess
    import sys
    subprocess.run([sys.executable, str(ROOT/'Scripts/add_ui_tests.py')], check=True)
