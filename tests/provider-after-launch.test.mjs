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
  assert.match(dashboard, /initWithTitle:@"Providers"/);
  assert.match(dashboard, /omh.native.providers/);
  assert.match(dashboard, /@selector\(configureProvider\)/);
  for (const name of ['OpenAI', 'Anthropic', 'Gemini', 'DeepSeek', 'GLM \/ Z.AI', 'Kimi \/ Moonshot', 'Qwen'])
    assert.ok(dashboard.includes(name), name);
  assert.match(dashboard, /OMHProviderCredentials saveToken/);
  assert.match(dashboard, /secureTextEntry = YES/);
});

test('native brand chooses a compact iPhone title before the navigation bar first measures it', () => {
  const firstLayout = dashboard.indexOf('self.navigationItem.titleView = identity;');
  const compactText = dashboard.indexOf('self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ? @"OMH" : @"OpenMind Harness"');
  assert.ok(compactText >= 0 && compactText < firstLayout,
    'initial title must be compact before assigning the titleView');
  assert.match(dashboard, /brand\.accessibilityIdentifier = @"omh\.native\.brand\.logo"/);
  assert.match(dashboard, /available < 620 \? @"OMH" : @"OpenMind Harness"/);
  assert.match(dashboard, /if \(!\[self\.nativeTitle\.text isEqualToString:title\]\)/);
  assert.match(dashboard, /self\.navigationItem\.titleView = self\.navigationItem\.titleView;/);
});
