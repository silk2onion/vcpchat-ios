#!/usr/bin/env python3
"""Generate the checked-in iOS project from the shared SwiftUI app sources."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
files = sorted((root/'Sources/VChatApp').glob('*.swift'))
objects = []
def add(key, text): objects.append(f'{key} = {{{text}}};')
proj='A00000000000000000000001'; group='A00000000000000000000002'; products='A00000000000000000000003'; target='A00000000000000000000004'; product='A00000000000000000000005'; sources='A00000000000000000000006'; frameworks='A00000000000000000000007'; resources='A00000000000000000000008'; package='A00000000000000000000009'; core='A0000000000000000000000A'; coreBuild='A0000000000000000000000B'; configs='A0000000000000000000000C'; targetConfigs='A0000000000000000000000D'
refs=[]; builds=[]
for i,f in enumerate(files, 100):
    ref=f'B{i:023X}'; build=f'C{i:023X}';refs.append(ref);builds.append(build)
    add(ref,f'isa=PBXFileReference;lastKnownFileType=sourcecode.swift;path="{f.relative_to(root)}";sourceTree=SOURCE_ROOT;')
    add(build,f'isa=PBXBuildFile;fileRef={ref};')
add(group,f'isa=PBXGroup;children=({",".join(refs+["A0000000000000000000000E",products])});sourceTree="<group>";')
add(products,f'isa=PBXGroup;children=({product});name=Products;sourceTree="<group>";')
add(product,'isa=PBXFileReference;explicitFileType=wrapper.application;path=VChat.app;sourceTree=BUILT_PRODUCTS_DIR;')
add(sources,f'isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files=({",".join(builds)});runOnlyForDeploymentPostprocessing=0;')
add(coreBuild,f'isa=PBXBuildFile;productRef={core};')
add(frameworks,f'isa=PBXFrameworksBuildPhase;buildActionMask=2147483647;files=({coreBuild});runOnlyForDeploymentPostprocessing=0;')
add('A0000000000000000000000E','isa=PBXFileReference;lastKnownFileType=folder.assetcatalog;path=Configuration/Assets.xcassets;sourceTree=SOURCE_ROOT;')
add('A0000000000000000000000F','isa=PBXBuildFile;fileRef=A0000000000000000000000E;')
add(resources,'isa=PBXResourcesBuildPhase;buildActionMask=2147483647;files=(A0000000000000000000000F);runOnlyForDeploymentPostprocessing=0;')
add(package,'isa=XCLocalSwiftPackageReference;relativePath=".";')
add(core,f'isa=XCSwiftPackageProductDependency;package={package};productName=VChatCore;')
add(target,f'isa=PBXNativeTarget;buildConfigurationList={targetConfigs};buildPhases=({sources},{frameworks},{resources});buildRules=();dependencies=();name=VChat;productName=VChat;productReference={product};productType="com.apple.product-type.application";packageProductDependencies=({core});')
base='CLANG_ENABLE_MODULES=YES;SWIFT_VERSION=6.0;SWIFT_STRICT_CONCURRENCY=complete;IPHONEOS_DEPLOYMENT_TARGET=17.0;SDKROOT=iphoneos;'
for i,mode in enumerate(['Debug','Release']):
    p=f'D0000000000000000000000{i+1}';t=f'E0000000000000000000000{i+1}'
    debug='SWIFT_OPTIMIZATION_LEVEL="-Onone";SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG;ENABLE_TESTABILITY=YES;' if mode=='Debug' else 'SWIFT_OPTIMIZATION_LEVEL="-O";'
    add(p,f'isa=XCBuildConfiguration;name={mode};buildSettings={{{base}{debug}}};')
    add(t,f'isa=XCBuildConfiguration;name={mode};buildSettings={{{base}{debug}PRODUCT_BUNDLE_IDENTIFIER=app.vcpchat.native;ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon;PRODUCT_NAME=VChat;CODE_SIGN_STYLE=Automatic;TARGETED_DEVICE_FAMILY=1;GENERATE_INFOPLIST_FILE=NO;INFOPLIST_FILE=Configuration/Info.plist;LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks";}};')
add(configs,'isa=XCConfigurationList;buildConfigurations=(D00000000000000000000001,D00000000000000000000002);defaultConfigurationIsVisible=0;defaultConfigurationName=Release;')
add(targetConfigs,'isa=XCConfigurationList;buildConfigurations=(E00000000000000000000001,E00000000000000000000002);defaultConfigurationIsVisible=0;defaultConfigurationName=Release;')
add(proj,f'isa=PBXProject;attributes={{LastUpgradeCheck=1600;}};buildConfigurationList={configs};compatibilityVersion="Xcode 14.0";developmentRegion=zh-Hans;knownRegions=("zh-Hans",en,Base);mainGroup={group};productRefGroup={products};projectDirPath="";projectRoot="";targets=({target});packageReferences=({package});')
p=root/'VChat.xcodeproj/project.pbxproj';p.parent.mkdir(exist_ok=True)
p.write_text('// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={\n'+'\n'.join(objects)+f'\n}};rootObject={proj};}}\n')
