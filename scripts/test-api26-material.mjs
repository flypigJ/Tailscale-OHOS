import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import baseline from './verify-sdk-baseline.cjs';

const sdkFields = ['compileSdkVersion', 'compatibleSdkVersion', 'targetSdkVersion'];
const sdkProduct = () => Object.fromEntries(sdkFields.map(field => [field, '26.0.0']));
const profile = () => ({ app: { products: [sdkProduct(), sdkProduct()] } });
const browser = readFileSync(new URL('../entry/src/main/ets/components/TaildriveBrowser.ets', import.meta.url), 'utf8');
const builder = name => {
  const start = browser.indexOf(`  private ${name}()`);
  assert.notEqual(start, -1, name);
  const end = browser.indexOf('\n  @Builder', start);
  return browser.slice(start, end === -1 ? undefined : end);
};

test('every product explicitly compiles, targets and requires API 26', () => {
  assert.equal(baseline.verifySdkBaseline(profile()), 2);
  const example = JSON.parse(readFileSync(new URL('../build-profile.example.json5', import.meta.url), 'utf8'));
  assert.equal(baseline.verifySdkBaseline(example), 1);
});

for (const field of sdkFields) {
  for (const value of ['6.1.0(23)', '6.0.0(20)', '27.0.0', 26, undefined]) {
    test(`${field} rejects an unsupported or implicit SDK in a later product: ${value}`, () => {
      const candidate = profile();
      candidate.app.products[1][field] = value;
      assert.throws(() => baseline.verifySdkBaseline(candidate), new RegExp(field));
    });
  }
}

test('missing products cannot silently inherit a lower SDK', () => {
  for (const candidate of [{}, { app: {} }, { app: { products: [] } }, { app: { products: [null] } }]) {
    assert.throws(() => baseline.verifySdkBaseline(candidate));
  }
});

test('both build entries verify the SDK baseline before building the native core', () => {
  for (const filename of ['build.ps1', 'build.sh']) {
    const script = readFileSync(new URL(filename, import.meta.url), 'utf8');
    assert.ok(script.indexOf('verify-sdk-baseline.cjs') < script.indexOf(filename === 'build.ps1' ? "'build-go.ps1'" : 'scripts/build-go.sh'));
  }
  for (const filename of ['build.ps1', 'build-go.ps1', 'verify-artifacts.ps1']) {
    const script = readFileSync(new URL(filename, import.meta.url), 'utf8');
    assert.doesNotMatch(script, /harmony-sdk-23|OpenHarmony\\Sdk\\(?:23|6\.1)/);
  }
});

test('artifact checks require the compiler-normalized API 26 and select only the requested product', () => {
  const script = readFileSync(new URL('verify-artifacts.ps1', import.meta.url), 'utf8');
  assert.match(script, /minAPIVersion -ne 260000026/);
  assert.match(script, /targetAPIVersion -ne 260000026/);
  assert.match(script, /entry\\build\\\$Product\\outputs\\default/);
  assert.doesNotMatch(script, /Get-ChildItem[\s\S]*?-Recurse/);
});

test('file actions are actually hosted in a horizontal native bottom TabBar', () => {
  const standalone = builder('StandaloneBrowser');
  assert.match(standalone, /Tabs\(\{ barPosition: BarPosition\.End \}\)/);
  assert.match(standalone, /TabContent\(\)/);
  assert.match(standalone, /\.tabBar\(this\.FileToolbarHost\)/);
  assert.match(standalone, /\.vertical\(false\)/);
  assert.match(standalone, /\.scrollable\(false\)/);
  assert.match(standalone, /\.barOverlap\(true\)/);
  assert.match(standalone, /\.barHeight\(this\.fileToolbarHeight\(\), true\)/);
  assert.doesNotMatch(standalone, /TabsController|Stack\(\{ alignContent: Alignment\.Bottom/);
  assert.match(builder('FileToolbarHost'), /this\.BottomToolbar\(\)/);
});

test('toolbar materials use API 26 without custom blur or low-SDK branches', () => {
  const normal = builder('NormalBottomToolbar');
  assert.equal((normal.match(/\.systemMaterial\(LightAppearance\.toolbarButton\(this\.glowLevel\)\)/g) || []).length, 4);
  assert.match(builder('SelectionBottomToolbar'), /\.systemMaterial\(LightAppearance\.toolbarGroup\(this\.glowLevel\)\)/);
  for (const toolbar of [normal, builder('SelectionBottomToolbar')]) {
    assert.doesNotMatch(toolbar, /backgroundBlurStyle|backgroundEffect|backdropBlur|canIUse|sdkVersion/);
  }
  assert.match(browser, /import \{ LightAppearance \} from '\.\/LightAppearance'/);
  assert.match(builder('StandaloneNavigation'), /systemMaterialEffect:/);
  assert.doesNotMatch(browser, /new uiMaterial\.ImmersiveMaterial\(/,
    'toolbar roles are configured by the shared factory');
});

test('toolbar material bindings select factory roles with the current reactive preference', () => {
  const toolbar = builder('NormalBottomToolbar') + builder('SelectionBottomToolbar');
  const expressions = Array.from(toolbar.matchAll(
    /\.systemMaterial\((LightAppearance\.(?:toolbarButton|toolbarGroup)\(this\.glowLevel\))\)/g), match => match[1]);
  assert.equal(expressions.length, 5);
  const calls = [];
  const sandbox = { LightAppearance: {
    toolbarButton: level => { const result = { role: 'toolbarButton', level }; calls.push(result); return result; },
    toolbarGroup: level => { const result = { role: 'toolbarGroup', level }; calls.push(result); return result; }
  } };
  vm.runInNewContext('globalThis.materials = function () { return [' + expressions.join(',') + ']; };', sandbox);
  for (const level of [0, 1, 2, 3]) {
    const roles = sandbox.materials.call({ glowLevel: level });
    assert.deepEqual(Array.from(roles, material => material.role),
      ['toolbarButton', 'toolbarButton', 'toolbarButton', 'toolbarButton', 'toolbarGroup']);
    assert.ok(roles.every(material => material.level === level));
  }
  assert.equal(calls.length, 20);
  assert.match(browser, /@Prop\s+glowLevel: number\s*=\s*3/);
});

test('toolbar height preserves the existing safe-area offset and hides disconnected actions', () => {
  const method = browser.match(/  private fileToolbarHeight\(\): number \{[\s\S]*?\n  \}/)[0];
  const sandbox = {};
  vm.runInNewContext(stripTypeScriptTypes(`
    const TAILDRIVE_TOOLBAR_HEIGHT = 52;
    const TAILDRIVE_SELECTION_TOOLBAR_HEIGHT = 48;
    ${method.replace('  private ', 'function ')}
    globalThis.measure = fileToolbarHeight;
  `), sandbox);
  assert.equal(sandbox.measure.call({ connected: false, selectionMode: false, bottomInset: 106 }), 0);
  assert.equal(sandbox.measure.call({ connected: true, selectionMode: false, bottomInset: 106 }), 142);
  assert.equal(sandbox.measure.call({ connected: true, selectionMode: true, bottomInset: 106 }), 138);
  assert.equal(sandbox.measure.call({ connected: true, selectionMode: false, bottomInset: 0 }), 52);
  assert.equal(sandbox.measure.call({ connected: true, selectionMode: true, bottomInset: -10 }), 48);
});

test('API 26 material configuration stays in the Stage entry without adding sensor permissions', () => {
  const module = JSON.parse(readFileSync(new URL('../entry/src/main/module.json5', import.meta.url), 'utf8')).module;
  assert.equal(module.type, 'entry');
  assert.deepEqual(module.metadata.find(item => item.name === 'ohos.arkui.UIMaterial.state'), {
    name: 'ohos.arkui.UIMaterial.state', value: 'default'
  });
  assert.equal(module.requestPermissions.some(permission => /LIGHT|SENSOR/.test(permission.name)), false);
});
