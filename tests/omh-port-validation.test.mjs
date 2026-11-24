import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const root=resolve(import.meta.dirname,'..');
const harness=join(root,'harness');
const read=p=>readFile(join(root,p),'utf8');

test('official app branding is a real committed WebP, not the terminal placeholder',async()=>{
 const icon=await readFile(join(root,'branding/omh-hexagon.webp'));
 assert.equal(icon.toString('ascii',0,4),'RIFF');
 assert.equal(icon.toString('ascii',8,12),'WEBP');
 assert.ok(icon.length>1000);
 await access(join(root,'scripts/sync-omh-branding.sh'));
});
test('the Alpine iPad rootfs explicitly bundles the latest MCP tools and Bubblewrap',async()=>{
 const build=await read('scripts/build-rootfs.sh');
 assert.match(build,/apk add[^\n]*bubblewrap/);
 assert.match(build,/omh-\{dashboard,runtime,mcp,daemon,live\}\.mjs/);
 assert.match(build,/cp -R "\$HARNESS_DIR\/lib" "\$runtime\/"/);
 // Vercel is fully out of the harness (PR #11) and out of this repo:
 // the Vercel connector and wrapper must not be referenced in the build.
 assert.doesNotMatch(build,/connect-vercel-mcp|omh-vercel-mcp/);
 assert.match(build,/guest dashboard did not serve a valid/i);
 assert.match(build,/c\.mcp\?\.\["omh-runtime"\]\?\.enabled/);
 assert.match(build,/sandbox\.verified/);
});
test('iPad launchers use persistent OMH configuration and the real dashboard API',async()=>{
 const editor=await read('rootfs/overlay/usr/local/bin/opencode-serve');
 assert.match(editor,/\/root\/\.config\/opencode\/opencode\.json/);
 const dashboard=await read('rootfs/overlay/usr/local/bin/omh-dashboard');
 assert.match(dashboard,/omh-dashboard\.mjs/);
 const harnessFile=await read('app/OMHHarness.m');
 assert.match(harnessFile,/api\/state/);
 const probe=await read('app/OMHReadinessProbe.m');
 assert.match(probe,/req\.HTTPMethod = @"GET"/);
 assert.doesNotMatch(probe,/ok = code > 0 && code < 500/);
});
test('guest wrappers are present and do not silently run unsandboxed commands',async()=>{
 for(const script of ['omh-runtime','omh-dashboard','omh-sandbox-check','omh-live']){
  const source=await read('rootfs/overlay/usr/local/bin/'+script);
  assert.match(source,/\/usr\/bin\/node/);
  assert.doesNotMatch(source,/danger-full-access/);
 }
});
test('Xcode CI runs simulator and pins the same validated harness used for branding',async()=>{
 const workflow=await read('.github/workflows/build-ipa.yml');
 // All harness checkouts must pin the same revision; the revision itself
 // changes whenever the pin is updated, so assert consistency, not a
 // specific SHA (a hard-coded SHA breaks on every pin update).
 const refs=[...workflow.matchAll(/ref: ([0-9a-f]{40})/g)].map(m=>m[1]);
 assert.ok(refs.length>=1,'workflow pins a harness revision');
 assert.ok(new Set(refs).size===1,'all harness checkouts pin the same revision: '+[...new Set(refs)].join(', '));
 assert.match(workflow,/scripts\/sync-omh-branding\.sh/);
 assert.match(workflow,/simctl bootstatus/);
 assert.match(workflow,/xcodebuild -project/);
});
test('canonical harness model and official icon agree when harness checkout is present',async t=>{
 try{await access(join(harness,'opencode.json'));}
 catch{t.skip('Harness checkout not mounted outside GitHub CI');return;}
 const config=JSON.parse(await readFile(join(harness,'opencode.json'),'utf8'));
 assert.equal(config.model,'google/gemini-3.5-flash-lite');
 assert.equal(config.agent.planner.model,config.model);
 const a=await readFile(join(harness,'dashboard/app-icon.webp'));
 const b=await readFile(join(root,'branding/omh-hexagon.webp'));
 assert.deepEqual(a,b);
});

test('provider key persistence test navigates through editor and reboots for fresh environment',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 const editor=await read('app/OMHRootViewController.m');
 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 assert.match(scene,/initWithRootViewController:\[OMHDashboardViewController new\]/);
 assert.match(scene,/omh\.native\.settings/);
 assert.match(scene,/actionWithTitle:@"OpenCode"/);
 assert.match(editor,/identifier:@"omh\.menu"/);
 assert.match(editor,/@\"Provider Connections\"/);
 assert.match(editor,/\[OMHHarness\.shared restart\];\s*\[OMHHarness\.dashboard restart\];/);
 assert.match(ui,/\[self openEditorProviderMenu\];/);
 assert.match(ui,/\[self openEditorFromSettings\];/);
 assert.match(ui,/\[self\.app terminate\];\s*\[self\.app launch\];/);
 assert.match(ui,/Exactly one provider \(DeepSeek\) must read configured after the restart/);
 assert.match(ui,/No provider should remain configured after cleanup/);
});

test('new IPA identity is OMH.app and the legacy bundle is rejected',async()=>{
 const config=await read('app/AppOMH.xcconfig');
 const projectGenerator=await read('scripts/gen-xcode-project.rb');
 const ci=await read('.github/workflows/build-ipa.yml');
 assert.match(config,/^PRODUCT_NAME = OMH$/m);
 assert.match(config,/^MARKETING_VERSION = 1\.0\.17$/m);
 assert.match(projectGenerator,/OMH\.app\/OMH/);
 assert.match(ci,/Payload\/OMH\.app\/OMH/);
 assert.match(ci,/Payload\/DSH\.app/);
 const make=await read('Makefile');
 assert.match(make,/Release-iphoneos\/OMH\.app/);
});

test('full-screen startup gate controls dashboard readiness and optional provider setup',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 assert.match(scene,/@interface OMHLaunchGateController : UIViewController/);
 assert.match(scene,/initWithRootViewController:\[OMHDashboardViewController new\]/);
 assert.match(scene,/self\.window\.rootViewController = gate;/);
 assert.match(scene,/self\.window\.rootViewController = nav;/);
 assert.match(scene,/OMHBootPhaseReady && server\.state == OMHHarnessStateReady/);
 assert.doesNotMatch(scene,/omh\.launch\.configure-provider/);
 assert.match(scene,/actionWithTitle:@"Providers"/);
 assert.match(scene,/\[OMHProviderCredentials saveToken:value provider:provider\]/);
 assert.match(scene,/\[OMHHarness\.dashboard restart\]/);
 assert.match(scene,/omh\.launch\.continue/);
 assert.match(ui,/waitForDashboardLaunch/);
 assert.match(ui,/Dashboard chrome must remain hidden during boot/);
 assert.match(ui,/Startup gate must be removed, not overlaid over the dashboard/);
});

test('dashboard root has no empty left navigation control',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 assert.match(scene,/self\.navigationItem\.leftBarButtonItem = nil;/);
 assert.doesNotMatch(scene,/initWithCustomView:self\.loadingIndicator/);
});

test('one native OMH dashboard shell supports both iOS iPhone and iPadOS',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 assert.match(scene,/One native UIKit shell on both iPhone/);
 assert.match(scene,/CGRectGetWidth\(self\.view\.bounds\)/);
 assert.match(scene,/available < 620 \? @"OMH"/);
 // No browser engine in the dashboard any more: the WebView and its
 // content-mode configuration are gone; the container installs native
 // Chat and Runtime views in a content area under the header instead.
 assert.doesNotMatch(scene,/WKContentModeRecommended/);
 assert.doesNotMatch(scene,/\[WKWebView /);
 assert.match(scene,/installNativeContent/);
 assert.match(scene,/OMHChatViewController alloc/);
 assert.match(scene,/OMHRuntimeViewController alloc/);
 assert.match(scene,/contentView\.accessibilityIdentifier = @"omh\.native\.dashboard"/);
 assert.match(scene,/initWithRootViewController:\[OMHDashboardViewController new\]/);
 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 assert.match(ui,/testIOSPhoneNativeDashboardAndEditor/);
 assert.match(ui,/testHarnessBootsAndShowsNativeUI/);
 const ci=await read('.github/workflows/build-ipa.yml');
 assert.match(ci,/^  iphone-simulator-smoke:/m);
 assert.match(ci,/^  simulator-smoke:/m);
 assert.match(ci,/pick-iphone-simulator\.sh/);
 assert.match(ci,/testIOSPhoneNativeDashboardAndEditor/);
});
