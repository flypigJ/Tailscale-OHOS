import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const root = new URL('../entry/src/main/', import.meta.url);
function fixture() {
  const source = ['MoonlightIntegrationConfig', 'MoonlightLauncher'].map(name =>
    readFileSync(new URL(`ets/services/${name}.ets`, root), 'utf8')
      .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '')).join('\n');
  let available = true, fail = false;
  const wants = [], links = [];
  const context = vm.createContext({ bundleManager: { canOpenLink(uri) {
    links.push(uri); if (fail) throw new Error('query failed'); return available;
  } } });
  vm.runInContext(stripTypeScriptTypes(source) + '\nglobalThis.Launcher = MoonlightLauncher;', context);
  const launcher = new context.Launcher({ async startAbility(want) { wants.push(want); } });
  return { launcher, wants, links, available(value) { available = value; }, fail() { fail = true; } };
}
const request = { protocolVersion: 1, action: 'openHost', source: 'MeshArc', host: '100.64.0.10',
  displayName: 'PC', pathType: 'derp', streamProfile: { profileName: 'relay_safe', recommendedBitrateKbps: 5000,
    recommendedWidth: 1280, recommendedHeight: 720, recommendedFps: 60, allowUserOverride: true } };

test('launch carries v1 host, relay limit and automatic streaming to the verified bundle', async () => {
  const f = fixture(); await f.launcher.launch(request);
  const want = f.wants[0]; assert.equal(want.bundleName, 'com.alkaidlab.sdream');
  assert.equal(want.abilityName, 'EntryAbility'); assert.equal(want.moduleName, 'entry');
  assert.equal(want.uri, 'moonlight-mesharc://host');
  assert.equal(want.parameters.host, request.host); assert.equal(want.parameters.pathType, 'derp');
  assert.equal(want.parameters.recommendedBitrateKbps, 5000);
  assert.equal(want.parameters.autoStream, true); assert.equal(want.parameters.adaptiveBitrate, true);
});

test('original configuration explicitly disables MeshArc bitrate policy', async () => {
  const f = fixture(); await f.launcher.launch({ ...request, adaptiveBitrate: false });
  assert.equal(f.wants[0].parameters.adaptiveBitrate, false);
});

test('missing or old client and failed capability query never dispatch a launch', async () => {
  for (const fail of [false, true]) {
    const f = fixture(); if (fail) f.fail(); else f.available(false);
    assert.equal(await f.launcher.isAvailable(), false);
    await assert.rejects(f.launcher.launch(request)); assert.equal(f.wants.length, 0);
  }
});

test('capability scheme is declared for nonprivileged canOpenLink lookup', () => {
  const module = JSON.parse(readFileSync(new URL('module.json5', root), 'utf8'));
  assert.ok(module.module.querySchemes.includes('moonlight-mesharc'));
});
