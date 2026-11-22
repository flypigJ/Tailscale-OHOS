import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = file => readFileSync(new URL('../entry/src/main/ets/components/' + file, import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n');
const sources = {
  BridgeStatus: read('BridgeStatus.ets'),
  NativeSettingsNavigation: read('NativeSettingsNavigation.ets'),
  TaildriveBrowser: read('TaildriveBrowser.ets'),
  BackgroundRunningSettings: read('BackgroundRunningSettings.ets'),
  CompactConnectedHomeHeader: read('CompactConnectedHomeHeader.ets'),
  DeviceDetailSheet: read('DeviceDetailSheet.ets'),
  ConnectionDetailsSheet: read('ConnectionDetailsSheet.ets'),
  UpdateChangelogSheet: read('UpdateChangelogSheet.ets')
};
const appearance = read('LightAppearance.ets');

function method(source, name) {
  const start = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(start, 'production method ' + name);
  const end = source.indexOf('\n  }', start.index);
  assert.ok(end > start.index, name + ' closing brace');
  return source.slice(start.index, end + 4);
}

// Follow the component's own modifier chain rather than accepting a material from a nearby sibling.
function matchingEnd(source, start, opening, closing) {
  let depth = 0, quote = '', comment = '';
  for (let i = start; i < source.length; i++) {
    const char = source[i], next = source[i + 1];
    if (comment === 'line') { if (char === '\n') comment = ''; continue; }
    if (comment === 'block') { if (char === '*' && next === '/') { comment = ''; i++; } continue; }
    if (quote) {
      if (char === '\\') { i++; continue; }
      if (char === quote) quote = '';
      continue;
    }
    if (char === '/' && next === '/') { comment = 'line'; i++; continue; }
    if (char === '/' && next === '*') { comment = 'block'; i++; continue; }
    if (char === '"' || char === "'" || char === '`') { quote = char; continue; }
    if (char === opening) depth++;
    else if (char === closing && --depth === 0) return i;
  }
  assert.fail('unclosed production component at ' + start);
}

function components(source, name) {
  const result = [];
  for (const match of source.matchAll(new RegExp('^\\s*' + name + '\\(', 'gm'))) {
    const start = match.index + match[0].lastIndexOf(name);
    let end = matchingEnd(source, start + name.length, '(', ')') + 1;
    let cursor = end;
    const skipWhitespace = () => { while (/\s/.test(source[cursor] ?? '') && cursor < source.length) cursor++; };
    skipWhitespace();
    if (source[cursor] === '{') { end = matchingEnd(source, cursor, '{', '}') + 1; cursor = end; }
    const modifierStart = end;
    while (cursor < source.length) {
      skipWhitespace();
      const modifier = /^\.\w+\(/.exec(source.slice(cursor));
      if (!modifier) break;
      const argumentStart = cursor + modifier[0].length - 1;
      end = matchingEnd(source, argumentStart, '(', ')') + 1;
      cursor = end;
    }
    result.push({ text: source.slice(start, end), modifiers: source.slice(modifierStart, end),
      line: source.slice(0, start).split('\n').length });
  }
  return result;
}

for (const name of ['BridgeStatus', 'NativeSettingsNavigation']) {
  for (const control of ['Toggle', 'Slider', 'Select']) {
    test(`${name} ${control} controls attach native material to their own component`, () => {
      const blocks = components(sources[name], control);
      assert.ok(blocks.length > 0, name + ' contains ' + control);
      for (const block of blocks) {
        assert.match(block.modifiers, /\.systemMaterial\(LightAppearance\.control\((?:this\.(?:glowLevel|materialIndex)|\$\$\.glowLevel)\)\)/,
          `${name}:${block.line} ${control}`);
        if (control === 'Select') {
          assert.match(block.modifiers, /\.menuSystemMaterial\(LightAppearance\.menu\(this\.(?:glowLevel|materialIndex)\)\)/,
            `${name}:${block.line} Select menu has its own material`);
          assert.doesNotMatch(block.modifiers, /\.menuBackground(?:BlurStyle|Color)\(/,
            `${name}:${block.line} Select menu does not obscure native material with its old background`);
        }
      }
    });
  }
}

test('content buttons keep native press feedback without claiming title-bar-only system material', () => {
  for (const name of ['BridgeStatus', 'NativeSettingsNavigation']) {
    for (const button of components(sources[name], 'Button')) {
      assert.doesNotMatch(button.modifiers, /\.systemMaterial\(/, `${name}:${button.line} content Button`);
    }
  }
  assert.equal(/\.pointLight\(/.test(sources.BridgeStatus), false,
    'scrolling content does not place fixed HDS point sources on moving controls');
});

test('native slider and toggle builders receive the material preference as part of their reactive object', () => {
  const source = sources.NativeSettingsNavigation;
  for (const name of ['ToggleRow', 'SliderRow']) {
    const definition = method(source, name);
    assert.match(definition, new RegExp(name + '\\(\\$\\$: NativeSettings(?:Toggle|Slider)Data\\)'));
    assert.match(definition, /\.systemMaterial\(LightAppearance\.control\(\$\$\.glowLevel\)\)/);
    const calls = Array.from(source.matchAll(new RegExp('this\\.' + name + '\\(\\{', 'g')));
    assert.ok(calls.length > 0, name + ' call sites');
    for (const call of calls) {
      const argumentStart = call.index + call[0].length - 2;
      const argumentEnd = matchingEnd(source, argumentStart, '(', ')');
      assert.match(source.slice(argumentStart, argumentEnd), /glowLevel: this\.materialIndex/);
    }
  }
});

test('the saved appearance preference reaches file controls and all HDS hosts through the shared policy', () => {
  const files = method(sources.BridgeStatus, 'FilesContent');
  assert.match(files, /TaildriveBrowser\(\{[\s\S]*?glowLevel: this\.glowLevel/);
  assert.match(sources.TaildriveBrowser, /@Prop\s+glowLevel: number\s*=\s*3/);
  for (const [source, typeMethod, levelMethod] of [
    [sources.BridgeStatus, 'glowMaterialType', 'glowMaterialLevel']
  ]) {
    assert.match(method(source, typeMethod), /LightAppearance\.hdsType\(this\.glowLevel\)/);
    assert.match(method(source, levelMethod), /LightAppearance\.hdsLevel\(this\.glowLevel\)/);
  }
  const nativeTitle = method(sources.NativeSettingsNavigation, 'modalTitleBar');
  assert.match(nativeTitle, /LightAppearance\.hdsType\(this\.materialIndex\)/);
  assert.match(nativeTitle, /LightAppearance\.hdsLevel\(this\.materialIndex\)/);
  assert.match(nativeTitle, /blurStrategy: LightAppearance\.blurStrategy\(this\.materialIndex\)/);
  const fileNavigation = method(sources.TaildriveBrowser, 'StandaloneNavigation');
  assert.match(fileNavigation, /materialType: LightAppearance\.hdsType\(this\.glowLevel\)/);
  assert.match(fileNavigation, /materialLevel: LightAppearance\.hdsLevel\(this\.glowLevel\)/);
  assert.match(fileNavigation, /blurStrategy: LightAppearance\.blurStrategy\(this\.glowLevel\)/);
});

test('material configuration uses actual API fields and retains API 26 Stage defaults', () => {
  assert.doesNotMatch(appearance, /\bquality\s*:/, 'ImmersiveOptions has no configurable quality field');
  assert.doesNotMatch(appearance, /sdkVersion|canIUse|apiVersion\s*[<>=]/,
    'capability queries are not an unsupported lower-SDK fallback');
  const module = JSON.parse(readFileSync(new URL('../entry/src/main/module.json5', import.meta.url), 'utf8')).module;
  assert.deepEqual(module.metadata.find(item => item.name === 'ohos.arkui.UIMaterial.state'), {
    name: 'ohos.arkui.UIMaterial.state', value: 'default'
  });
});

test('nested Toggle and Select controls attach native material', () => {
  const bgToggles = components(sources.BackgroundRunningSettings, 'Toggle');
  assert.equal(bgToggles.length, 1);
  assert.match(bgToggles[0].modifiers, /\.systemMaterial\(LightAppearance\.control\(\$\$\.glowLevel\)\)/);
  const compactSelects = components(sources.CompactConnectedHomeHeader, 'Select');
  assert.equal(compactSelects.length, 1);
  assert.match(compactSelects[0].modifiers, /\.systemMaterial\(LightAppearance\.control\(this\.glowLevel\)\)/);
  assert.match(compactSelects[0].modifiers, /\.menuSystemMaterial\(LightAppearance\.menu\(this\.glowLevel\)\)/);
});

test('all 8 settings detail sub-pages wire settingsDetailTitleBar with HDS material and GRADIENT_BLUR', () => {
  const helper = method(sources.BridgeStatus, 'settingsDetailTitleBar');
  assert.match(helper, /scrollEffectType:\s*ScrollEffectType\.GRADIENT_BLUR/);
  assert.match(helper, /materialType:\s*this\.glowMaterialType\(\)/);
  assert.match(helper, /materialLevel:\s*this\.glowMaterialLevel\(\)/);
  assert.match(helper, /blurStrategy:\s*LightAppearance\.blurStrategy\(this\.glowLevel\)/);
  const pageMap = method(sources.BridgeStatus, 'SettingsDetailPageMap');
  assert.equal((pageMap.match(/\.titleBar\(this\.settingsDetailTitleBar\(/g) || []).length, 8);
  assert.equal((pageMap.match(/\.onShown\(/g) || []).length, 8);
});

test('all 12 bindSheet hosts wire LightAppearance.sheet without obscuring SheetOptions.backgroundColor', () => {
  const bridgeSheets = method(sources.BridgeStatus, 'RootSheetHosts');
  assert.equal((bridgeSheets.match(/\.bindSheet\(/g) || []).length, 7);
  assert.equal((bridgeSheets.match(/systemMaterial:\s*LightAppearance\.sheet\(this\.glowLevel\)/g) || []).length, 7);
  assert.doesNotMatch(bridgeSheets, /backgroundColor:/);

  const taildriveSheets = method(sources.TaildriveBrowser, 'SheetHosts');
  assert.equal((taildriveSheets.match(/\.bindSheet\(/g) || []).length, 5);
  assert.equal((taildriveSheets.match(/systemMaterial:\s*LightAppearance\.sheet\(this\.glowLevel\)/g) || []).length, 5);
  assert.doesNotMatch(taildriveSheets, /backgroundColor:/);

  for (const name of ['DeviceDetailSheet', 'ConnectionDetailsSheet', 'UpdateChangelogSheet']) {
    assert.match(sources[name], /LightAppearance\.supports\(\)\s*\?\s*Color\.Transparent\s*:\s*\$r\('sys\.color\.background_secondary'\)/, name);
  }
});

test('menus, CustomDialog, and Toast wire native API 26 material while keeping dialogs VM-isolated', () => {
  assert.match(sources.BridgeStatus, /\.bindMenu\([\s\S]*?systemMaterial:\s*LightAppearance\.menu\(this\.glowLevel\)/);
  assert.equal((sources.TaildriveBrowser.match(/systemMaterial:\s*LightAppearance\.menu\(this\.glowLevel\)/g) || []).length, 2);
  assert.match(method(sources.BridgeStatus, 'openContextGuide'), /systemMaterial:\s*LightAppearance\.dialog\(this\.glowLevel\)/);
  assert.match(sources.DeviceDetailSheet, /systemMaterial:\s*LightAppearance\.dialog\(this\.glowLevel\)/);
  assert.match(method(sources.BridgeStatus, 'showToast'), /systemMaterial:\s*LightAppearance\.toast\(this\.glowLevel\)/);
});

test('feature guide entry is card-wrapped and disclosure chevrons use icon_secondary', () => {
  const settings = method(sources.BridgeStatus, 'SettingsContent');
  assert.match(settings, /settings-feature-guide-entry[\s\S]*?\.backgroundColor\(this\.groupBackground\(\)\)\s*\.borderRadius\(UiTokens\.CARD_RADIUS\)/);
  for (const name of ['BridgeStatus', 'NativeSettingsNavigation']) {
    for (const chevron of components(sources[name], 'SymbolGlyph').filter(c => /chevron_(?:right|down)/.test(c.text))) {
      assert.doesNotMatch(chevron.modifiers, /app\.color\.emphasize/, `${name}:${chevron.line} chevron color`);
    }
  }
});
