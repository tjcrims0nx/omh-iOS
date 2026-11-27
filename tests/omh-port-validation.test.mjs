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
 assert.match(scene,/actionWithTitle:@"Workspace"/);
 assert.match(editor,/identifier:@"omh\.menu"/);
 assert.match(editor,/@\"Provider Connections\"/);
 assert.match(editor,/\[OMHHarness\.shared restart\];\s*\[OMHHarness\.dashboard restart\];/);
 assert.match(ui,/\[self openEditorProviderMenu\];/);
 assert.match(ui,/\[self openEditorFromSettings\];/);
 assert.match(ui,/\[self\.app terminate\];\s*\[self\.app launch\];/);
 assert.match(ui,/Exactly one provider \(DeepSeek\) must read configured after the restart/);
 assert.match(ui,/No provider should remain configured after cleanup/);
});

test('every provider offered in the settings sheet has a Keychain mapping',async()=>{
 const scene=await read('app/OMHSceneDelegate.m');
 const creds=await read('app/OMHProviderCredentials.m');
 // The sheet's provider ids (the @"groq" values in the dictionary) must
 // each have an entry in OMHProviderCredentials.names, or saveToken
 // refuses to save them and the user gets "Key not saved" (f6224a1 added
 // Groq/Together/OpenRouter to the sheet without the mapping).
 const block=scene.match(/NSDictionary<NSString \*,NSString \*> \*providers = @\{([\s\S]*?)\};/);
 assert.ok(block,'provider sheet dictionary must exist');
 const ids=[...block[1].matchAll(/@"[^"]*":@"(\w+)"/g)].map(m=>m[1]);
 assert.ok(ids.length>=10,'provider sheet must list at least ten providers');
 for (const id of ids) {
  assert.match(creds,new RegExp(`@"${id}":@"[A-Z_]+_API_KEY"`),`Keychain map must know provider ${id}`);
 }
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

test('coding runtime starts at boot on both idioms and gates the dashboard',async()=>{
 const boot=await read('app/OMHBootCoordinator.m');
 const scene=await read('app/OMHSceneDelegate.m');
 // The coding runtime (opencode serve, port 3080) must start during
 // initial boot on iPad as well as iPhone; excluding iPad left the
 // Workspace editor showing a second startup screen (d9cd1f5).
 assert.match(boot,/\[OMHHarness\.dashboard start\];/);
 assert.match(boot,/\[OMHHarness\.shared start\];/);
 assert.doesNotMatch(boot,/UIUserInterfaceIdiomPad[\s\S]{0,200}\[OMHHarness\.shared start\]/);
 assert.doesNotMatch(boot,/if \(UIDevice\.currentDevice\.userInterfaceIdiom != UIUserInterfaceIdiomPad\)\s*\n\s*\[OMHHarness\.shared start\];/);
 // The startup gate must not complete until BOTH the dashboard API and
 // the coding runtime are ready (3c71ff4).
 assert.match(scene,/OMHHarness\.dashboard\.state != OMHHarnessStateReady \|\|\s*\n?\s*OMHHarness\.shared\.state != OMHHarnessStateReady/);
 assert.match(scene,/server\.state == OMHHarnessStateReady && runtime\.state == OMHHarnessStateReady/);
});

test('selected chat provider persists across launches without storing secrets',async()=>{
 const chat=await read('app/OMHChatViewController.m');
 // Only the non-secret provider identifier is saved in preferences;
 // the API key itself stays in the Keychain (757a802).
 assert.match(chat,/stringForKey:@"omh\.chat\.selectedProvider\.v1"/);
 assert.match(chat,/setObject:provider\.providerId forKey:@"omh\.chat\.selectedProvider\.v1"/);
 assert.doesNotMatch(chat,/setObject:.*(?:token|apiKey|API_KEY).*forKey:@"omh\.chat\.selectedProvider\.v1"/);
 // Restore only matches a provider that is currently configured.
 assert.match(chat,/\[provider\.providerId isEqualToString:savedID\] && provider\.available/);
 // Unconfigured providers cannot be selected, and sending requires a
 // configured provider (nil-safe: messaging nil returns NO).
 assert.match(chat,/if \(!provider\.available\) \{\s*\n\s*self\.statusLabel\.text = @"Configure this provider in Settings first\.";/);
 assert.match(chat,/self\.sendButton\.enabled = \(self\.selectedProvider\.available && !self\.sending && !composerDisabled\)/);
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
 assert.match(scene,/OMHReferenceDashboardFactory makeWithBaseURL/);
 const swift=await read("app/OMHReferenceDashboard.swift");
 assert.match(swift,/import SwiftUI/);
 assert.match(swift,/UIHostingController\(rootView:/);
 assert.match(swift,/minimumInterval: 1\.0 \/ 45\.0/);
 assert.match(swift,/truncatingRemainder\(dividingBy: 12\)/);
 assert.match(swift,/omh\.native\.chat\.composer/);
 assert.match(swift,/omh\.swiftui\.conversations\.v1/);
 // The factory must carry no actor isolation on its Objective-C surface:
 // a @MainActor annotation on the class or the method hides it from the
 // generated OMH-Swift.h (CI runs 45896757219 and 45907478634). The
 // hosting controller is still built on the main actor, via
 // MainActor.assumeIsolated inside make.
 assert.doesNotMatch(swift,/@MainActor final class OMHReferenceDashboardFactory/);
 assert.doesNotMatch(swift,/@MainActor\s*\n\s*@objc\(makeWithBaseURL/);
 assert.match(swift,/MainActor\.assumeIsolated/);
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

test('native Workspace home lists projects and sessions, WebView only as labelled legacy fallback',async()=>{
 const root=await read('app/OMHRootViewController.m');
 // The Workspace home is native UIKit, not the WebView: the WebView starts
 // hidden and the native workspace is built in its place (5ac5a29).
 assert.match(root,/self\.webView\.hidden = YES;/);
 assert.match(root,/\[self buildNativeWorkspace\];/);
 assert.match(root,/self\.nativeWorkspaceTable = table;/);
 assert.match(root,/table\.accessibilityIdentifier = @"omh\.workspace\.native\.list";/);
 // Projects and sessions come from the local runtime API, with a
 // generation guard so a stale response cannot overwrite a newer one.
 assert.match(root,/for \(NSString \*path in @\[@\"\/project\", @\"\/session\"\]\)/);
 assert.match(root,/NSURL \*url = \[NSURL URLWithString:path relativeToURL:base\];/);
 assert.match(root,/NSUInteger generation = \+\+self\.workspaceRequestGeneration;/);
 assert.match(root,/if \(!self \|\| generation != self\.workspaceRequestGeneration\) return;/);
 // Native search filters both sections by label.
 assert.match(root,/self\.workspaceSearch\.delegate = self;/);
 assert.match(root,/localizedCaseInsensitiveContainsString:query/);
 // Real loading, empty and error states, not a spinner that never resolves.
 assert.match(root,/self\.workspaceStatus\.text = @"Loading projects and sessions…";/);
 assert.match(root,/@"No projects or sessions found\."/);
 assert.match(root,/@"Some workspace data could not be loaded\. Tap Refresh to retry\."/);
 assert.match(root,/self\.workspaceStatus\.text = @"Local runtime unavailable\.";/);
 // The old editor survives only as an explicitly labelled legacy fallback;
 // opening it hides the native workspace, closing it restores it.
 assert.match(root,/editorStyle\.title = @"Open session editor \(legacy\)";/);
 assert.match(root,/editor\.accessibilityIdentifier = @"omh\.workspace\.legacy-editor";/);
 assert.match(root,/- \(void\)openLegacyWorkspaceEditor \{/);
 assert.match(root,/self\.nativeWorkspace\.hidden = YES;/);
 assert.match(root,/self\.webView\.hidden = NO;/);
 // Loading the harness must not load the WebView when the native
 // Workspace is home: it hides the overlay and refreshes the list.
 assert.match(root,/if \(!self\.legacyEditorVisible\) \{\s*\n\s*self\.loadedPort = OMHHarness\.shared\.port;/);
 assert.match(root,/\[self refreshNativeWorkspace\];/);
});

test('custom providers are registered, configurable and routed natively',async()=>{
 const creds=await read('app/OMHProviderCredentials.m');
 const credsHeader=await read('app/OMHProviderCredentials.h');
 const verifier=await read('app/OMHProviderVerifier.m');
 const api=await read('app/OMHApiClient.m');
 const scene=await read('app/OMHSceneDelegate.m');
 const swift=await read('app/OMHReferenceDashboard.swift');
 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 // Keychain credential manager knows both custom providers.
 assert.match(creds,/@\"custom-openai\":@\"OPENMIND_CUSTOM_OPENAI_API_KEY\"/);
 assert.match(creds,/@\"custom-anthropic\":@\"OPENMIND_CUSTOM_ANTHROPIC_API_KEY\"/);
 assert.match(credsHeader,/isCustomProvider/);
 assert.match(creds,/customProviderBaseURL/);
 assert.match(creds,/customProviderModel/);
 assert.match(creds,/saveCustomProvider:[^\n]*baseURL:[^\n]*model:/);
 assert.match(creds,/removeCustomProvider:/);
 // The base URL and model ID are not secrets (UserDefaults); only the
 // API key is in the Keychain. No token is ever written to UserDefaults.
 assert.doesNotMatch(creds,/setObject:.*(?:token|apiKey).*forKey:.*custom/);
 // Connection verifier handles both custom protocols against the
 // user-configured URL, with per-protocol auth and redirects blocked.
 assert.match(verifier,/customVerifyEndpointForProvider/);
 assert.match(verifier,/isCustomProvider/);
 assert.match(verifier,/custom-anthropic/);
 assert.match(verifier,/x-api-key/);
 assert.match(verifier,/anthropic-version/);
 assert.match(verifier,/OMHNoRedirectDelegate/);
 // The provider setup sheet offers both custom providers.
 assert.match(scene,/@\"Custom OpenAI\":@\"custom-openai\"/);
 assert.match(scene,/@\"Custom Anthropic\":@\"custom-anthropic\"/);
 assert.match(scene,/promptForCustomProvider:/);
 assert.match(scene,/\[OMHProviderVerifier verifyProvider:provider completion:/);
 // The API client merges custom providers into the list and routes their
 // chat directly to the configured endpoint (OpenAI-compatible or
 // Anthropic), not via the harness backend.
 assert.match(api,/customProviders/);
 assert.match(api,/sendCustomChatWithProvider/);
 assert.match(api,/customChatEndpointForProvider/);
 assert.match(api,/chat\/completions/);
 assert.match(api,/v1\/messages/);
 assert.match(api,/OMHApiClientCustomNoRedirectDelegate/);
 assert.match(api,/isCustomProvider:providerId/);
 // The SwiftUI dashboard merges custom providers, routes their chat
 // directly, and provides a native config screen.
 assert.match(swift,/CustomProviderStore/);
 assert.match(swift,/custom-openai/);
 assert.match(swift,/custom-anthropic/);
 assert.match(swift,/sendCustom/);
 assert.match(swift,/verifyCustom/);
 assert.match(swift,/CustomProviderSettingsView/);
 assert.match(swift,/omh\.custom\.configure/);
 assert.match(swift,/NoRedirectDelegate/);
 assert.match(swift,/import Security/);
 // Regression test: configuring a custom provider makes it appear in
 // the selector and selectable, then removes it.
 assert.match(ui,/testCustomProviderConfigurationAppearsInSelector/);
 assert.match(ui,/omh\.custom\.openai\.url/);
 assert.match(ui,/omh\.custom\.openai\.save/);
 assert.match(ui,/omh\.custom\.openai\.remove/);
});
test('custom provider persistence is proven by a mock-endpoint regression test',async()=>{
 const ui=await read('tests/OMHUITests/OMHLaunchUITests.m');
 const mock=await read('tests/mock-custom-provider-server.py');
 const workflow=await read('.github/workflows/build-ipa.yml');
 // The mock server is deterministic and local: it answers the OpenAI and
 // Anthropic chat protocols plus the models list, and it returns a 302
 // for the redirect probe. It must never log credential header names, and
 // its log_message must print only the method and path (never headers or
 // bodies, which can carry API keys).
 assert.match(mock,/127\.0\.0\.1/);
 assert.match(mock,/18080/);
 assert.match(mock,/\/v1\/chat\/completions/);
 assert.match(mock,/\/v1\/messages/);
 assert.match(mock,/\/v1\/models/);
 assert.match(mock,/\/redirect\/models/);
 assert.match(mock,/mock openai reply/);
 assert.match(mock,/mock anthropic reply/);
 assert.doesNotMatch(mock,/Authorization|x-api-key/);
 assert.match(mock,/def log_message[\s\S]*?print\(f"\{self\.command\} \{self\.path\}"/);
 // The persistence test configures both providers against the mock
 // server, restarts the app, verifies the config survived (URLs and
 // models in UserDefaults, keys recovered from the Keychain), routes a
 // request through each protocol after the restart, and proves removing
 // one provider does not affect the other.
 assert.match(ui,/testCustomProviderPersistenceAcrossRestart/);
 assert.match(ui,/127\.0\.0\.1:18080/);
 assert.match(ui,/mock-openai-model/);
 assert.match(ui,/mock-anthropic-model/);
 assert.match(ui,/API key \(saved\)/);
 assert.match(ui,/mock openai reply/);
 assert.match(ui,/mock anthropic reply/);
 assert.match(ui,/Provider verification failed/);
 assert.match(ui,/\[self\.app terminate\]/);
 // The iPad CI job must start the mock server before the tests and run
 // both new custom-provider UI tests; otherwise the persistence test
 // never executes.
 assert.match(workflow,/mock-custom-provider-server\.py/);
 assert.match(workflow,/testCustomProviderConfigurationAppearsInSelector/);
 assert.match(workflow,/testCustomProviderPersistenceAcrossRestart/);
});
