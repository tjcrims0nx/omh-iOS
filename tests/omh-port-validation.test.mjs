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
 assert.match(build,/connect-vercel-mcp\.mjs/);
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
 for(const script of ['omh-runtime','omh-dashboard','omh-sandbox-check','omh-vercel-mcp','omh-live']){
  const source=await read('rootfs/overlay/usr/local/bin/'+script);
  assert.match(source,/\/usr\/bin\/node/);
  assert.doesNotMatch(source,/danger-full-access/);
 }
});
test('Xcode CI runs simulator and pins the same validated harness used for branding',async()=>{
 const workflow=await read('.github/workflows/build-ipa.yml');
 assert.match(workflow,/ref: 55f62a9ad23fa897c21fa40948716b5c5504e626/);
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

test('native iPad workspace and iPhone dashboard share a supervised OMH runtime',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 assert.match(scene,/@interface OMHNativeIPadController : UIViewController/);
 assert.match(scene,/UIDevice\.currentDevice\.userInterfaceIdiom == UIUserInterfaceIdiomPad/);
 assert.match(scene,/\[OMHNativeIPadController new\] : \[OMHDashboardViewController new\]/);
 assert.match(scene,/omh\.native\.ipad\.sidebar/);
 assert.match(scene,/omh\.native\.ipad\.content/);
 assert.match(scene,/URLByAppendingPathComponent:@"api\/state"/);
 assert.match(scene,/WKContentModeRecommended/);
 assert.match(scene,/self\.sidebarWidthConstraint = \[self\.sectionsTable\.widthAnchor constraintEqualToConstant:246\]/);
 assert.match(scene,/floor\(width \* 0\.32\)/);
 assert.match(scene,/self\.detailTable\.tableHeaderView = header/);
 assert.match(scene,/selectRowAtIndexPath:indexPath animated:NO/);
 // iPad restores dashboard connectivity when foregrounded and must never
 // keep stale tasks or a stale worker status when guest runtime disconnects.
 assert.match(scene,/@interface OMHStartupViewController : UIViewController/);
 assert.match(scene,/omh\.startup\.status/);
 assert.match(scene,/OMHBootStateDidChangeNotification/);
 assert.match(scene,/OMHHarnessStateDidChangeNotification/);
 assert.match(scene,/server\.state == OMHHarnessStateReady/);
 assert.match(scene,/editor\.state == OMHHarnessStateReady/);
 assert.match(scene,/omh\.startup\.toggle-logs/);
 assert.match(scene,/editor\.log\.diagnosticReport/);
 const boot=await read('app/OMHBootCoordinator.m');
 assert.match(boot,/\[OMHHarness\.dashboard start\];\s*\[OMHHarness\.shared start\];/);

 assert.match(scene,/\[strongNav setViewControllers:@\[home\] animated:NO\]/);
 assert.match(scene,/initWithRootViewController:isIPad \? startup : home/);
 assert.match(scene,/\[root isKindOfClass:OMHNativeIPadController\.class\]/);
 assert.match(scene,/\[OMHHarness\.dashboard verifyAliveWithCompletion:nil\]/);
 assert.match(scene,/\+\+self\.requestGeneration;/);
 assert.match(scene,/self\.runtimeState = nil;/);
 assert.match(scene,/strongSelf\.runtimeState = state;/);
 assert.match(scene,/\[state\[@"worker"\]\[@"online"\] boolValue\]/);

 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 assert.match(ui,/testIOSPhoneNativeDashboardAndEditor/);
 assert.match(ui,/testHarnessBootsAndShowsWebUI/);
 assert.match(ui,/omh\.startup\.status/);
 assert.match(ui,/omh\.startup\.toggle-logs/);
 assert.match(ui,/waitForExistenceWithTimeout:kBootTimeout/);

 const ci=await read('.github/workflows/build-ipa.yml');
 assert.match(ci,/^  iphone-simulator-smoke:/m);
 assert.match(ci,/^  simulator-smoke:/m);
 assert.match(ci,/pick-iphone-simulator\.sh/);
 assert.match(ci,/testIOSPhoneNativeDashboardAndEditor/);
});
