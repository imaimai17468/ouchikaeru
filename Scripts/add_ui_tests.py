"""Add the real API UI smoke test without replacing signing or scheme settings."""
from pathlib import Path
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project_path = root / 'Ouchikaeru.xcodeproj/project.pbxproj'
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_path)]))
objects = project['objects']
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def add(key, isa, **fields):
    ident = uid(key)
    objects[ident] = dict(isa=isa, **fields)
    return ident
name = 'OuchikaeruUITests'
app_id = next(key for key, value in objects.items() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Ouchikaeru')
file_ref = add('UITests/RouteFlowTests.swift', 'PBXFileReference', lastKnownFileType='sourcecode.swift', path='UITests/RouteFlowTests.swift', sourceTree='<group>')
build_file = add(name + 'file', 'PBXBuildFile', fileRef=file_ref)
sources = add(name + 'sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[build_file], runOnlyForDeploymentPostprocessing=0)
product = add(name + 'product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path=name + '.xctest', sourceTree='BUILT_PRODUCTS_DIR')
configs = []
for config in ['Debug', 'Release']:
    configs.append(add(name + config, 'XCBuildConfiguration', name=config, buildSettings=dict(
        PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='jp.ouchikaeru.app.uitests', SDKROOT='iphoneos',
        SUPPORTED_PLATFORMS='iphoneos iphonesimulator', IPHONEOS_DEPLOYMENT_TARGET='17.0', SWIFT_VERSION='5.0',
        TARGETED_DEVICE_FAMILY='1', GENERATE_INFOPLIST_FILE='YES', TEST_TARGET_NAME='Ouchikaeru',
        CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM='RWMY2QRJ24',
        SWIFT_OPTIMIZATION_LEVEL='-Onone' if config == 'Debug' else '-O')))
config_list = add(name + 'configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
proxy = add(name + 'proxy', 'PBXContainerItemProxy', containerPortal=project['rootObject'], proxyType=1, remoteGlobalIDString=app_id, remoteInfo='Ouchikaeru')
dependency = add(name + 'dependency', 'PBXTargetDependency', target=app_id, targetProxy=proxy)
target = add(name, 'PBXNativeTarget', name=name, productName=name, buildConfigurationList=config_list, buildPhases=[sources], buildRules=[], dependencies=[dependency], productReference=product, productType='com.apple.product-type.bundle.ui-testing')
project_object = objects[project['rootObject']]
for collection, item in [(project_object['targets'], target), (objects[project_object['mainGroup']]['children'], file_ref), (objects[project_object['productRefGroup']]['children'], product)]:
    if item not in collection: collection.append(item)
def encode(value):
    if isinstance(value, dict): return '{\n' + '\n'.join(f'{encode(k)} = {encode(v)};' for k, v in value.items()) + '\n}'
    if isinstance(value, list): return '(' + ','.join(encode(v) for v in value) + ')'
    if isinstance(value, int): return str(value)
    return json.dumps(value, ensure_ascii=False)
project_path.write_text('// !$*UTF8*$!\n' + encode(project) + '\n')
scheme_path = root / 'Ouchikaeru.xcodeproj/xcshareddata/xcschemes/Ouchikaeru.xcscheme'
tree = ET.parse(scheme_path)
scheme = tree.getroot()
action = scheme.find('TestAction')
if action is None:
    action = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
action.attrib.pop('shouldAutocreateTestPlan', None)
testables = action.find('Testables')
if testables is None: testables = ET.SubElement(action, 'Testables')
if not any(ref.get('BlueprintIdentifier') == target for ref in testables.iter('BuildableReference')):
    test = ET.SubElement(testables, 'TestableReference', skipped='NO', parallelizable='NO')
    ET.SubElement(test, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=target, BuildableName=name + '.xctest', BlueprintName=name, ReferencedContainer='container:Ouchikaeru.xcodeproj')
ET.indent(tree, space='   ')
tree.write(scheme_path, encoding='UTF-8', xml_declaration=True)
print('Added UI test target; existing application build settings preserved.')
