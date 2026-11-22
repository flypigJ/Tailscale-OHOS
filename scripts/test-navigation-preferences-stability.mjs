import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/services/NavigationPreferences.ets', import.meta.url), 'utf8')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');
test('corrupt stored margins never become nonfinite layout dimensions', async () => {
  for (const margin of [NaN, Infinity, -Infinity, 'invalid', null]) {
    const sandbox = { preferences: { getPreferences: async () => ({
      getSync: (key, fallback) => key === 'navigation_bottom_margin' ? margin : fallback
    }) } };
    vm.runInNewContext(stripTypeScriptTypes(source) + '\nthis.Preferences = NavigationPreferences;', sandbox);
    const settings = await sandbox.Preferences.load({});
    assert.equal(settings.bottomMargin, 30, String(margin));
  }
});
