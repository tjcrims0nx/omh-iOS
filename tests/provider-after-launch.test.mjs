import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const scene = await readFile(new URL('../app/OMHSceneDelegate.m', import.meta.url), 'utf8');
const dashboard = scene.split('@implementation OMHDashboardViewController')[1].split('@end')[0];
const launch = scene.split('@implementation OMHLaunchGateController')[1].split('@end')[0];

test('first-run gate does not ask for a provider or create dashboard early', () => {
  assert.doesNotMatch(launch, /Configure provider|configureProvider|promptForKey|configureButton/);
  assert.match(launch, /OMHBootPhaseReady && server.state == OMHHarnessStateReady/);
  assert.match(launch, /Open dashboard/);
  assert.match(scene, /self.window.rootViewController = gate/);
  assert.match(scene, /gate.onReady = \^\{/);
});

test('dashboard exposes optional universal provider configuration', () => {
  assert.match(dashboard, /omh\.native\.settings/);
  assert.match(dashboard, /actionWithTitle:@"Providers"/);
  assert.match(dashboard, /\[weakSelf configureProvider\]/);
  for (const name of ['OpenAI', 'Anthropic', 'Gemini', 'DeepSeek', 'GLM \/ Z.AI', 'Kimi \/ Moonshot', 'Qwen'])
    assert.ok(dashboard.includes(name), name);
  assert.match(dashboard, /OMHProviderCredentials saveToken/);
  assert.match(dashboard, /secureTextEntry = YES/);
});

test('native brand header chooses a compact iPhone title without a navigation titleView', () => {
  // The brand lives in a dedicated responsive header above the WebView,
  // not in the navigation bar: the bar collapsed the titleView on a
  // compact iPhone so the logo never appeared.
  assert.doesNotMatch(dashboard, /self\.navigationItem\.titleView = identity;/);
  assert.match(dashboard, /self\.headerView = \[UIView new\]/);
  assert.match(dashboard, /\[self\.headerView addSubview:identity\]/);
  assert.match(dashboard, /self\.dashboard\.topAnchor constraintEqualToAnchor:self\.headerView\.bottomAnchor/);
  assert.match(dashboard, /brand\.accessibilityIdentifier = @"omh\.native\.brand\.logo"/);
  assert.match(dashboard, /available < 620 \? @"OMH" : @"OpenMind Harness"/);
  assert.match(dashboard, /if \(!\[self\.nativeTitle\.text isEqualToString:title\]\)/);
});
