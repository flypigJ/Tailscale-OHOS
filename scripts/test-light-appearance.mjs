import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/components/LightAppearance.ets', import.meta.url), 'utf8')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');

function fixture(options = {}) {
  const queries = { supported: 0, device: 0, state: 0, hds: 0 };
  const allocated = [];
  const shadows = [];
  const logs = [];
  const empty = { empty: true };
  const uiMaterial = {
    MaterialLevel: { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 },
    MaterialState: { DEFAULT: 0, ENABLE: 1, DISABLE: 2 },
    ImmersiveStyle: options.ultraThick ? { THIN: 1, THICK: 3, ULTRA_THICK: 4 } : { THIN: 1, THICK: 3 },
    Material: class { static get empty() { return empty; } },
    ImmersiveMaterial: class {
      constructor(settings) {
        this.settings = JSON.parse(JSON.stringify(settings));
        allocated.push(this);
      }
    },
    isImmersiveMaterialSupported() {
      queries.supported++;
      if (options.supportError) throw new Error('support');
      return options.supported ?? true;
    },
    getGlobalMaterialLevel() {
      queries.device++;
      if (options.deviceError) throw new Error('device');
      return options.deviceLevel ?? 0;
    },
    getMaterialInfo() {
      queries.state++;
      if (options.stateError) throw new Error('state');
      return { state: options.state ?? 0 };
    }
  };
  const hdsMaterial = {
    MaterialLevel: { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2, ADAPTIVE: 10 },
    MaterialType: { NONE: 0, ADAPTIVE: 100, IMMERSIVE: 101 },
    getSystemMaterialTypes() {
      queries.hds++;
      if (options.hdsError) throw new Error('hds');
      return options.hdsTypes ?? [101];
    }
  };
  const hdsEffect = {
    PressShadowType: { NONE: 0, BLEND_WHITE: 1, BLEND_GRADIENT: 2 },
    HdsEffectBuilder: class {
      pointLight() { assert.fail('pointLight must never be allocated for scrolling content'); }
      pressShadow(value) { this.shadow = value; return this; }
      buildEffect() { const effect = { shadow: this.shadow }; shadows.push(effect); return effect; }
    }
  };
  const BlurStrategy = { ENABLE: 0, DISABLE: 1, ADAPTIVE: 2 };
  const hilog = { info: (...args) => logs.push(args) };
  const sandbox = { uiMaterial, hdsMaterial, hdsEffect, BlurStrategy, hilog, Color: { White: '#FFFFFFFF' } };
  vm.runInNewContext(stripTypeScriptTypes(source) + '\nthis.Appearance = LightAppearance;', sandbox);
  return { Appearance: sandbox.Appearance, queries, allocated, shadows, logs, empty, BlurStrategy };
}

test('all native roles use legal options without a writable quality or opaque color override', () => {
  const { Appearance: A } = fixture();
  for (const level of [0, 1, 2, 3]) {
    for (const role of ['control', 'menu', 'toolbarButton', 'toolbarGroup']) {
      const { settings } = A[role](level);
      assert.equal(settings.style, role === 'menu' ? 3 : 1);
      assert.equal(settings.colorInvert, role !== 'menu');
      assert.equal('quality' in settings, false);
      assert.equal('materialLevel' in settings, false);
      assert.equal('materialColor' in settings, false);
      assert.deepEqual(Object.keys(settings).sort(),
        ['applyShadow', 'colorInvert', 'interactive', 'lightEffect', 'style']);
    }
  }
});

test('manual levels vary app feedback while keeping native component style and quality untouched', () => {
  const { Appearance: A } = fixture();
  for (const role of ['control', 'toolbarButton']) {
    assert.deepEqual(A[role](0).settings, {
      style: 1, colorInvert: true, applyShadow: true, interactive: true,
      lightEffect: { color: '#FFFFFFFF' }
    });
    assert.deepEqual(A[role](1).settings, {
      style: 1, colorInvert: true, applyShadow: true, interactive: false,
      lightEffect: { color: '#FFFFFFFF' }
    });
    assert.deepEqual(A[role](2).settings, {
      style: 1, colorInvert: true, applyShadow: false, interactive: false, lightEffect: null
    });
  }
  for (const level of [0, 1, 2]) {
    assert.equal(A.toolbarGroup(level).settings.interactive, false);
    assert.equal(A.toolbarGroup(level).settings.lightEffect, null);
    assert.equal(A.menu(level).settings.interactive, false);
    assert.equal(A.menu(level).settings.lightEffect, null);
  }
});

test('native support and application disable gates return the cached empty material', () => {
  for (const options of [{ supported: false }, { supportError: true }, { state: 2 },
    { stateError: true }, { state: 99 }]) {
    const { Appearance: A, empty, allocated } = fixture(options);
    assert.equal(A.supports(), false);
    for (const level of [0, 1, 2, 3]) {
      for (const role of ['control', 'menu', 'toolbarButton', 'toolbarGroup']) {
        assert.equal(A[role](level), empty);
      }
    }
    assert.equal(allocated.length, 0);
  }
});

test('explicit application disable also disables HDS type and additional feedback', () => {
  const { Appearance: A, BlurStrategy } = fixture({ state: 2 });
  for (const level of [0, 1, 2, 3]) {
    assert.equal(A.hdsType(level), 0);
    assert.equal(A.pressEffect(level, true).shadow, 0);
    assert.equal(A.blurStrategy(level), BlurStrategy.DISABLE);
  }
});

test('auto uses read-only device levels for additional app strategy and retains HDS ADAPTIVE', () => {
  for (const deviceLevel of [0, 1, 2]) {
    const { Appearance: A, BlurStrategy } = fixture({ deviceLevel });
    assert.deepEqual(A.toolbarButton(3).settings, A.toolbarButton(deviceLevel).settings);
    assert.equal(A.backgroundRadius(3), [28, 18, 10][deviceLevel]);
    assert.equal(A.backgroundSaturation(3), [1.38, 1.2, 1.05][deviceLevel]);
    assert.equal(A.backgroundBrightness(3), [1.12, 1.07, 1.02][deviceLevel]);
    assert.equal(A.hdsLevel(3), 10);
    assert.equal(A.hdsType(3), 100);
    assert.equal(A.blurStrategy(3), BlurStrategy.ADAPTIVE);
  }
});

test('unknown device level or query failure uses the least additional feedback', () => {
  for (const options of [{ deviceLevel: 99 }, { deviceError: true }]) {
    const { Appearance: A } = fixture(options);
    assert.equal(A.control(3).settings.interactive, false);
    assert.equal(A.control(3).settings.lightEffect, null);
    assert.equal(A.backgroundRadius(3), 10);
    assert.equal(A.hdsLevel(3), 10);
  }
});

test('HDS manual grades honor capability while preserving auto and stored numeric preference', () => {
  const { Appearance: supported } = fixture();
  assert.deepEqual([0, 1, 2, 3].map(level => supported.hdsLevel(level)), [0, 1, 2, 10]);
  assert.deepEqual([0, 1, 2, 3].map(level => supported.hdsType(level)), [101, 101, 101, 100]);
  for (const options of [{ hdsTypes: [] }, { hdsTypes: [100] }, { hdsError: true }]) {
    const { Appearance: A } = fixture(options);
    for (const level of [0, 1, 2]) {
      assert.equal(A.hdsLevel(level), 2);
      assert.equal(A.hdsType(level), 100);
    }
    assert.equal(A.hdsLevel(3), 10);
    assert.equal(A.hdsType(3), 100);
  }
});

test('manual blur and background parameters retain the existing formulas', () => {
  const { Appearance: A, BlurStrategy } = fixture();
  assert.deepEqual([0, 1, 2].map(level => A.blurStrategy(level)),
    [BlurStrategy.ENABLE, BlurStrategy.ADAPTIVE, BlurStrategy.DISABLE]);
  assert.deepEqual([0, 1, 2].map(level => A.backgroundRadius(level)), [28, 18, 10]);
  assert.deepEqual([0, 1, 2].map(level => A.backgroundSaturation(level)), [1.38, 1.2, 1.05]);
  assert.deepEqual([0, 1, 2].map(level => A.backgroundBrightness(level)), [1.12, 1.07, 1.02]);
});

test('press feedback only uses button pressShadow and is absent when released', () => {
  const { Appearance: A } = fixture();
  assert.deepEqual([0, 1, 2].map(level => A.pressEffect(level, true).shadow), [2, 1, 0]);
  assert.deepEqual([0, 1, 2, 3].map(level => A.pressEffect(level, false).shadow), [0, 0, 0, 0]);
});

test('smooth, unsupported and disabled states retain native button press feedback', () => {
  const { Appearance: A } = fixture();
  assert.deepEqual([0, 1, 2].map(level => A.nativePress(level)), [false, false, true]);
  for (const deviceLevel of [0, 1, 2]) {
    const { Appearance: auto } = fixture({ deviceLevel });
    assert.equal(auto.nativePress(3), deviceLevel === 2);
  }
  for (const options of [{ supported: false }, { supportError: true }, { state: 2 }, { stateError: true }]) {
    const { Appearance: fallback } = fixture(options);
    for (const level of [0, 1, 2, 3]) {
      assert.equal(fallback.nativePress(level), true);
      assert.equal(fallback.pressEffect(level, true).shadow, 0);
    }
  }
});

test('capability diagnostics are emitted once with only the four non-sensitive fields', () => {
  const { Appearance: A, logs } = fixture({ deviceLevel: 1 });
  A.supports(); A.control(0); A.hdsType(3); A.nativePress(2);
  assert.equal(logs.length, 1);
  assert.deepEqual(logs[0], [0, 'UiMaterialPolicy',
    'immersiveSupported=%{public}s deviceLevel=%{public}d hdsImmersiveSupported=%{public}s materialState=%{public}d',
    'true', 1, 'true', 0]);
});

test('material and effect factories cache instances and query every capability at most once', () => {
  const { Appearance: A, queries } = fixture();
  for (const role of ['control', 'menu', 'toolbarButton', 'toolbarGroup']) {
    for (const level of [0, 1, 2, 3]) assert.equal(A[role](level), A[role](level));
  }
  assert.notEqual(A.control(0), A.menu(0));
  assert.notEqual(A.toolbarButton(0), A.toolbarGroup(0));
  assert.equal(A.pressEffect(0, true), A.pressEffect(0, true));
  A.hdsLevel(0); A.hdsType(3); A.supports(); A.backgroundRadius(3);
  assert.deepEqual(queries, { supported: 1, device: 1, state: 1, hds: 1 });
});

test('invalid preferences resolve as auto without writing or mutating any supplied preference', () => {
  const { Appearance: A } = fixture({ deviceLevel: 1 });
  for (const value of [-1, 4, NaN, Infinity, 0.5]) {
    assert.equal(A.control(value), A.control(3));
    assert.equal(A.hdsLevel(value), 10);
    assert.equal(A.hdsType(value), 100);
  }
});

test('floating surface roles (sheet, dialog, toast) use thick/ultra-thick styles and honor disable gate', () => {
  const withUltra = fixture({ ultraThick: true }).Appearance;
  const fallback = fixture().Appearance;
  for (const [A, expectedSheetStyle] of [[withUltra, 4], [fallback, 3]]) {
    for (const level of [0, 1, 2, 3]) {
      assert.deepEqual(A.sheet(level).settings, {
        style: expectedSheetStyle,
        colorInvert: false,
        applyShadow: level !== 2,
        interactive: false,
        lightEffect: null
      });
      assert.deepEqual(A.dialog(level).settings, {
        style: expectedSheetStyle,
        colorInvert: false,
        applyShadow: level !== 2,
        interactive: false,
        lightEffect: null
      });
      assert.deepEqual(A.toast(level).settings, {
        style: 3,
        colorInvert: false,
        applyShadow: level !== 2,
        interactive: false,
        lightEffect: null
      });
    }
  }
  const { Appearance: disabled, empty } = fixture({ state: 2, ultraThick: true });
  for (const role of ['sheet', 'dialog', 'toast']) {
    for (const level of [0, 1, 2, 3]) {
      assert.equal(disabled[role](level), empty);
    }
  }
});
