import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { stripEtsModuleSyntax } from './helpers/ets-vm-loader.mjs';

const read = file => readFileSync(new URL('../' + file, import.meta.url), 'utf8').replace(/\r\n/g, '\n');
const bridge = read('entry/src/main/ets/components/BridgeStatus.ets');
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
const atomicStore = stripEtsModuleSyntax(read('entry/src/main/ets/services/AtomicFileStore.ets'));
const personalization = stripEtsModuleSyntax(read('entry/src/main/ets/services/PersonalizationPreferences.ets'));
const settingsPreferencesGateway = stripEtsModuleSyntax(read('entry/src/main/ets/services/SettingsPreferencesGateway.ets'));

function method(source, name) {
  const start = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(start, 'production method ' + name);
  const end = source.indexOf('\n  }', start.index);
  assert.ok(end > start.index, name + ' closing brace');
  return source.slice(start.index, end + 4);
}

const controllerMethods = [
  'backgroundImageFilePath', 'immersiveColorFilePath', 'loadAppearancePreferences', 'saveAppearanceValue',
  'queuePersonalizationSave', 'flushPersonalizationPreferences', 'setPersonalizationColorMode',
  'setBackgroundBrightness', 'setImmersiveColorBackground', 'clearNativeSettingsBackground',
  'onBackgroundImageLoadError', 'selectNativeSettingsBackground', 'saveNavigationPreferences',
  'setNavigationBottomMargin', 'flushNavigationMarginPreferences'
];
const executable = stripTypeScriptTypes(atomicStore + '\n' + personalization + '\n' + settingsPreferencesGateway +
  '\nclass Controller {\n' +
  controllerMethods.map(name => method(bridge, name)).join('\n') +
  '\n}\nglobalThis.Controller = Controller;globalThis.Personalization = PersonalizationPreferences;globalThis.SettingsGateway = SettingsPreferencesGateway;');
const plain = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const filesDir = '/private/app';
const metadataPath = filesDir + '/ui-background-image-uri-v1';
const oldUri = 'file:///private/app/ui-backgrounds-v1/background-old-1.img';
const newUri = 'file:///private/app/ui-backgrounds-v1/background-new-2.img';

function fixture() {
  const f = {
    files: new Map([[metadataPath, oldUri]]), descriptors: new Map(), fileFailure: '', nextFd: 0,
    pickResults: [], importResults: [], imports: [], removed: [], toasts: [], events: [],
    timers: new Map(), nextTimer: 0, preferenceSaves: [], preferenceSaveResult: true,
    colorCalls: [], colorError: undefined, pickerConstructionError: undefined,
    navigationSaves: [], navigationGates: [], activeNavigationSaves: 0, maximumNavigationSaves: 0,
    persistedNavigation: undefined
  };
  const take = (queue, fallback) => {
    const result = queue.length ? queue.shift() : fallback;
    if (result instanceof Error) throw result;
    return result;
  };
  const context = { filesDir, getApplicationContext: () => ({ setColorMode: value => {
    f.colorCalls.push(value);
    if (f.colorError) throw f.colorError;
  } }) };
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: path => f.files.has(path),
    readTextSync: path => {
      if (!f.files.has(path)) throw Error('missing');
      return f.files.get(path);
    },
    openSync: path => {
      if (f.fileFailure === 'open') throw Error('open');
      const file = { fd: ++f.nextFd };
      f.descriptors.set(file.fd, path); f.files.set(path, ''); return file;
    },
    writeSync: (fd, value) => {
      if (f.fileFailure === 'write') throw Error('write');
      const bytes = new TextEncoder().encode(value).length;
      f.files.set(f.descriptors.get(fd), f.fileFailure === 'short_write' ? value.slice(0, -1) : value);
      return f.fileFailure === 'short_write' ? Math.max(0, bytes - 1) : bytes;
    },
    fsyncSync: () => { if (f.fileFailure === 'sync') throw Error('sync'); },
    closeSync: file => { assert.ok(f.descriptors.delete(file.fd)); },
    renameSync: (from, to) => {
      if (f.fileFailure === 'rename') throw Error('rename');
      assert.equal(f.descriptors.size, 0);
      assert.ok(f.files.has(from)); f.files.set(to, f.files.get(from)); f.files.delete(from);
    },
    unlinkSync: path => f.files.delete(path)
  };
  const sandbox = {
    fileIo, DiagnosticPrivacy: { utf8ByteLength: value => new TextEncoder().encode(value).length },
    ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: -1, COLOR_MODE_LIGHT: 101, COLOR_MODE_DARK: 202 } },
    SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 },
    photoAccessHelper: {
      PhotoViewPicker: class {
        constructor() { if (f.pickerConstructionError) throw f.pickerConstructionError; }
        select(options) {
          assert.equal(options.maxSelectNumber, 1); assert.equal(options.MIMEType, 'image');
          return take(f.pickResults, Promise.resolve({ photoUris: [] }));
        }
      },
      PhotoSelectOptions: class {}, PhotoViewMIMETypes: { IMAGE_TYPE: 'image' }
    },
    BackgroundImageStore: {
      importImage: (directory, uri) => {
        f.imports.push({ directory, uri }); return take(f.importResults, Promise.resolve(newUri));
      },
      removeManaged: (directory, uri) => f.removed.push({ directory, uri })
    },
    NavigationPreferences: { save: async (ctx, settings) => {
      assert.equal(ctx, context);
      f.navigationSaves.push(plain(settings));
      f.activeNavigationSaves++;
      f.maximumNavigationSaves = Math.max(f.maximumNavigationSaves, f.activeNavigationSaves);
      try {
        await take(f.navigationGates, Promise.resolve());
        f.persistedNavigation = plain(settings);
      } finally { f.activeNavigationSaves--; }
    } },
    setTimeout: (callback, delay) => { const id = ++f.nextTimer; f.timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => f.timers.delete(id),
    $r: id => id
  };
  vm.runInNewContext(executable, sandbox);
  sandbox.Personalization.save = (directory, settings) => {
    f.preferenceSaves.push({ directory, settings: plain(settings) }); return f.preferenceSaveResult;
  };
  const c = new sandbox.Controller();
  Object.assign(c, {
    lifecycleGeneration: 1, appShellReady: true, backgroundSelectionGeneration: 0,
    nativeSettingsBackgroundPickerInProgress: false, nativeSettingsBackgroundUri: oldUri,
    backgroundUnavailable: false, personalizationColorMode: 'system', backgroundBrightnessValue: 52,
    personalizationSaveTimer: -1, personalizationSavePending: false, navigationMarginSaveTimer: -1,
    navigationSaveQueue: Promise.resolve(), navigationOrder: ['home', 'transfer', 'files', 'settings'],
    hiddenNavigationTabs: [], navigationBottomMargin: 30,
    getUIContext: () => ({ getHostContext: () => context }),
    settingsPreferencesGateway: new sandbox.SettingsGateway(),
    showToast: value => f.toasts.push(value), recordFeatureDiagnosticEvent: (...event) => f.events.push(event)
  });
  f.c = c; f.sandbox = sandbox; f.context = context;
  f.runTimers = () => {
    for (const [id, timer] of [...f.timers]) { f.timers.delete(id); timer.callback(); }
  };
  // Simulate the same generation/readiness transitions performed by the actual lifecycle owner.
  f.teardown = () => { c.lifecycleGeneration++; c.appShellReady = false; };
  return f;
}

test('picker cancellation preserves the selected background and does not import or rewrite metadata', async () => {
  const f = fixture(); await f.c.selectNativeSettingsBackground();
  assert.equal(f.c.nativeSettingsBackgroundUri, oldUri);
  assert.equal(f.files.get(metadataPath), oldUri);
  assert.equal(f.imports.length, 0); assert.equal(f.removed.length, 0); assert.equal(f.toasts.length, 0);
  assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, false);
});

for (const stage of ['picker', 'import']) test(`${stage} failure retains the old selection and releases picker ownership`, async () => {
  const f = fixture();
  if (stage === 'picker') f.pickResults.push(Promise.reject({ code: 42 }));
  else {
    f.pickResults.push(Promise.resolve({ photoUris: ['picker://original'] }));
    f.importResults.push(Promise.reject({ code: 43 }));
  }
  await f.c.selectNativeSettingsBackground();
  assert.equal(f.c.nativeSettingsBackgroundUri, oldUri); assert.equal(f.files.get(metadataPath), oldUri);
  assert.equal(f.removed.length, 0); assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, false);
  assert.deepEqual(f.toasts, ['app.string.personalization_background_failed']);
});

test('picker initialization failure retains the previous background and allows another attempt', async () => {
  const f = fixture(); f.pickerConstructionError = { code: 44 };
  await assert.doesNotReject(f.c.selectNativeSettingsBackground());
  assert.equal(f.c.nativeSettingsBackgroundUri, oldUri); assert.equal(f.files.get(metadataPath), oldUri);
  assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, false);
  assert.deepEqual(f.toasts, ['app.string.personalization_background_failed']);
});

test('a successful imported candidate is persisted before the previous managed background is removed', async () => {
  const f = fixture(); f.c.backgroundUnavailable = true;
  f.pickResults.push(Promise.resolve({ photoUris: ['picker://original'] }));
  await f.c.selectNativeSettingsBackground();
  assert.equal(f.files.get(metadataPath), newUri); assert.equal(f.c.nativeSettingsBackgroundUri, newUri);
  assert.equal(f.c.backgroundUnavailable, false);
  assert.deepEqual(f.imports, [{ directory: filesDir, uri: 'picker://original' }]);
  assert.deepEqual(f.removed, [{ directory: filesDir, uri: oldUri }]);
  assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, false);
});

for (const failure of ['write', 'short_write', 'rename']) test(`${failure} during background metadata persistence keeps the old image and disposes only the candidate`, async () => {
  const f = fixture(); f.fileFailure = failure;
  f.pickResults.push(Promise.resolve({ photoUris: ['picker://original'] }));
  await f.c.selectNativeSettingsBackground();
  assert.equal(f.files.get(metadataPath), oldUri); assert.equal(f.c.nativeSettingsBackgroundUri, oldUri);
  assert.deepEqual(f.removed, [{ directory: filesDir, uri: newUri }]);
  assert.deepEqual(f.toasts, ['app.string.personalization_save_failed']);
  assert.equal(f.descriptors.size, 0); assert.equal(f.files.has(metadataPath + '.pending'), false);
});

test('clear withdraws a pending import, cleans its late candidate and cannot release a newer picker', async () => {
  const f = fixture(), importGate = deferred(), nextPicker = deferred();
  f.pickResults.push(Promise.resolve({ photoUris: ['picker://first'] }));
  f.importResults.push(importGate.promise);
  const first = f.c.selectNativeSettingsBackground(); await settle();
  f.c.clearNativeSettingsBackground();
  assert.equal(f.c.nativeSettingsBackgroundUri, ''); assert.equal(f.files.get(metadataPath), '');
  f.pickResults.push(nextPicker.promise);
  const second = f.c.selectNativeSettingsBackground();
  importGate.resolve(newUri); await first;
  assert.equal(f.c.nativeSettingsBackgroundUri, '');
  assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, true);
  assert.deepEqual(f.removed, [{ directory: filesDir, uri: oldUri }, { directory: filesDir, uri: newUri }]);
  nextPicker.resolve({ photoUris: [] }); await second;
  assert.equal(f.c.nativeSettingsBackgroundPickerInProgress, false);
});

test('teardown discards late imported candidates without rewriting the previous selection', async () => {
  const f = fixture(), gate = deferred();
  f.pickResults.push(Promise.resolve({ photoUris: ['picker://first'] })); f.importResults.push(gate.promise);
  const work = f.c.selectNativeSettingsBackground(); await settle(); f.teardown();
  gate.resolve(newUri); await work;
  assert.equal(f.files.get(metadataPath), oldUri); assert.equal(f.c.nativeSettingsBackgroundUri, oldUri);
  assert.deepEqual(f.removed, [{ directory: filesDir, uri: newUri }]); assert.equal(f.toasts.length, 0);
});

test('clear and teardown before the picker resolves prevent an import entirely', async () => {
  for (const transition of ['clear', 'teardown']) {
    const f = fixture(), gate = deferred(); f.pickResults.push(gate.promise);
    const work = f.c.selectNativeSettingsBackground();
    if (transition === 'clear') f.c.clearNativeSettingsBackground(); else f.teardown();
    gate.resolve({ photoUris: ['picker://late'] }); await work;
    assert.equal(f.imports.length, 0, transition);
    assert.equal(f.files.get(metadataPath), transition === 'clear' ? '' : oldUri, transition);
  }
});

test('clear persistence failure preserves the current choice and does not delete its image', () => {
  const f = fixture(); f.fileFailure = 'rename'; f.c.backgroundUnavailable = true;
  f.c.clearNativeSettingsBackground();
  assert.equal(f.files.get(metadataPath), oldUri); assert.equal(f.c.nativeSettingsBackgroundUri, oldUri);
  assert.equal(f.c.backgroundUnavailable, true); assert.equal(f.removed.length, 0);
  assert.deepEqual(f.toasts, ['app.string.personalization_save_failed']);
});

test('an old image error cannot hide a replacement and current errors retain the saved choice', () => {
  const f = fixture(); f.c.nativeSettingsBackgroundUri = newUri; f.files.set(metadataPath, newUri);
  f.c.onBackgroundImageLoadError(oldUri);
  assert.equal(f.c.backgroundUnavailable, false); assert.equal(f.toasts.length, 0);
  f.c.onBackgroundImageLoadError(newUri); f.c.onBackgroundImageLoadError(newUri);
  assert.equal(f.c.backgroundUnavailable, true); assert.equal(f.c.nativeSettingsBackgroundUri, newUri);
  assert.deepEqual(f.toasts, ['app.string.personalization_background_unavailable']);
  assert.equal(f.removed.length, 0); assert.equal(f.files.get(metadataPath), newUri);
});

test('appearance metadata writes preserve a complete UTF-8 URI and release its descriptor', () => {
  const f = fixture(), value = 'file:///private/app/背景图.img';
  assert.equal(f.c.saveAppearanceValue(metadataPath, value), true);
  assert.equal(f.files.get(metadataPath), value); assert.equal(f.descriptors.size, 0);
  assert.equal(f.files.has(metadataPath + '.pending'), false);
});

test('color API rejection leaves controller state and persistence untouched', () => {
  const f = fixture(); f.colorError = { code: 12 }; f.c.setPersonalizationColorMode(2);
  assert.equal(f.c.personalizationColorMode, 'system'); assert.deepEqual(f.colorCalls, [202]);
  assert.equal(f.preferenceSaves.length, 0); assert.equal(f.timers.size, 0);
  assert.deepEqual(f.toasts, ['app.string.personalization_apply_failed']);
});

test('a successful color choice applies before persisting and reports persistence failure separately', () => {
  const f = fixture(); f.preferenceSaveResult = false; f.c.setPersonalizationColorMode(1);
  assert.equal(f.c.personalizationColorMode, 'light'); assert.deepEqual(f.colorCalls, [101]);
  assert.deepEqual(f.preferenceSaves, [{ directory: filesDir, settings: { colorMode: 'light', backgroundBrightness: 52 } }]);
  assert.deepEqual(f.toasts, ['app.string.personalization_save_failed']);
  f.c.setPersonalizationColorMode(1); assert.equal(f.colorCalls.length, 1); assert.equal(f.timers.size, 0);
});

test('brightness rejects corrupt controls, clamps finite input and coalesces a drag to its latest setting', () => {
  const f = fixture();
  for (const value of [NaN, Infinity, -Infinity, '99', null, undefined]) f.c.setBackgroundBrightness(value, 1);
  assert.equal(f.c.backgroundBrightnessValue, 52); assert.equal(f.timers.size, 0);
  f.c.setBackgroundBrightness(-20, 1); assert.equal(f.c.backgroundBrightnessValue, 0);
  f.c.setBackgroundBrightness(200, 1); assert.equal(f.c.backgroundBrightnessValue, 100);
  f.c.setBackgroundBrightness(61.6, 1); assert.equal(f.c.backgroundBrightnessValue, 62);
  assert.equal(f.timers.size, 1); assert.equal(f.preferenceSaves.length, 0);
  f.runTimers();
  assert.equal(f.preferenceSaves.length, 1); assert.equal(f.preferenceSaves[0].settings.backgroundBrightness, 62);
  assert.equal(f.timers.size, 0);
});

test('brightness completion and lifecycle flush persist once and surface a failed save', () => {
  const f = fixture();
  f.c.setBackgroundBrightness(70, 1); f.c.setBackgroundBrightness(71, 2);
  assert.equal(f.preferenceSaves.length, 1); assert.equal(f.preferenceSaves[0].settings.backgroundBrightness, 71);
  assert.equal(f.timers.size, 0); f.c.flushPersonalizationPreferences(); assert.equal(f.preferenceSaves.length, 1);
  f.preferenceSaveResult = false;
  f.c.setBackgroundBrightness(72, 1); f.c.flushPersonalizationPreferences();
  assert.equal(f.preferenceSaves.length, 2); assert.equal(f.timers.size, 0);
  assert.deepEqual(f.toasts, ['app.string.personalization_save_failed']);
});

test('a failed personalization save remains dirty and a later lifecycle flush persists the latest active snapshot', () => {
  const f = fixture(); f.preferenceSaveResult = false;
  f.c.setBackgroundBrightness(73, 2);
  assert.equal(f.preferenceSaves.length, 1);
  assert.equal(f.c.backgroundBrightnessValue, 73);
  assert.equal(f.c.personalizationSavePending, true);
  f.preferenceSaveResult = true;
  f.c.flushPersonalizationPreferences();
  assert.equal(f.preferenceSaves.length, 2);
  assert.deepEqual(f.preferenceSaves[1], { directory: filesDir,
    settings: { colorMode: 'system', backgroundBrightness: 73 } });
  assert.equal(f.c.personalizationSavePending, false);
  assert.equal(f.timers.size, 0);
  f.c.flushPersonalizationPreferences();
  assert.equal(f.preferenceSaves.length, 2, 'a successfully saved choice is no longer dirty');
});

test('selecting the active color again retries an unsaved choice without repeating the platform color change', () => {
  const f = fixture(); f.preferenceSaveResult = false;
  f.c.setPersonalizationColorMode(2);
  assert.deepEqual(f.colorCalls, [202]);
  assert.equal(f.c.personalizationColorMode, 'dark');
  assert.equal(f.preferenceSaves.length, 1);
  f.preferenceSaveResult = true;
  f.c.setPersonalizationColorMode(2);
  assert.deepEqual(f.colorCalls, [202]);
  assert.equal(f.preferenceSaves.length, 2);
  assert.deepEqual(f.preferenceSaves[1], { directory: filesDir,
    settings: { colorMode: 'dark', backgroundBrightness: 52 } });
  assert.equal(f.c.personalizationSavePending, false);
});

test('rapid navigation snapshots execute serially and the last completed write contains the final choice', async () => {
  const f = fixture(), first = deferred(), second = deferred(); f.navigationGates.push(first.promise, second.promise);
  f.c.saveNavigationPreferences(); await settle();
  f.c.navigationOrder = ['settings', 'home', 'files', 'transfer']; f.c.hiddenNavigationTabs = ['files'];
  f.c.navigationBottomMargin = 60; f.c.saveNavigationPreferences();
  f.c.navigationOrder[1] = 'transfer'; f.c.navigationOrder[3] = 'home'; f.c.hiddenNavigationTabs.push('home'); f.c.navigationBottomMargin = 80;
  f.c.saveNavigationPreferences(); await settle();
  assert.equal(f.navigationSaves.length, 1); assert.equal(f.maximumNavigationSaves, 1);
  first.resolve(); await settle(); assert.equal(f.navigationSaves.length, 2);
  assert.deepEqual(f.navigationSaves[1], { order: ['settings', 'home', 'files', 'transfer'], hidden: ['files'], bottomMargin: 60 });
  second.resolve(); await f.c.navigationSaveQueue;
  assert.equal(f.maximumNavigationSaves, 1);
  assert.deepEqual(f.persistedNavigation, { order: ['settings', 'transfer', 'files', 'home'], hidden: ['files', 'home'], bottomMargin: 80 });
});

test('a failed navigation write reports feedback and does not poison subsequent queued writes', async () => {
  const f = fixture(), gate = deferred(); f.navigationGates.push(gate.promise);
  f.c.saveNavigationPreferences(); await settle();
  f.c.navigationBottomMargin = 66; f.c.saveNavigationPreferences(); gate.reject(Error('store unavailable'));
  await f.c.navigationSaveQueue;
  assert.equal(f.navigationSaves.length, 2); assert.equal(f.persistedNavigation.bottomMargin, 66);
  assert.deepEqual(f.toasts, ['app.string.personalization_save_failed']);
});

test('navigation margin rejects bad values, clamps updates and debounces persistence to the final position', async () => {
  const f = fixture();
  for (const value of [NaN, Infinity, -Infinity, '10', null, undefined]) f.c.setNavigationBottomMargin(value);
  assert.equal(f.c.navigationBottomMargin, 30); assert.equal(f.timers.size, 0);
  f.c.setNavigationBottomMargin(-1); assert.equal(f.c.navigationBottomMargin, 0);
  f.c.setNavigationBottomMargin(110); assert.equal(f.c.navigationBottomMargin, 100);
  f.c.setNavigationBottomMargin(47.6); assert.equal(f.c.navigationBottomMargin, 48);
  assert.equal(f.timers.size, 1); assert.equal(f.navigationSaves.length, 0);
  f.c.flushNavigationMarginPreferences(); await f.c.navigationSaveQueue;
  assert.equal(f.navigationSaves.length, 1); assert.equal(f.persistedNavigation.bottomMargin, 48);
  assert.equal(f.timers.size, 0); f.c.flushNavigationMarginPreferences(); await f.c.navigationSaveQueue;
  assert.equal(f.navigationSaves.length, 1);
});

const startupExecutable = stripTypeScriptTypes('class Startup {\n' +
  ['onWindowStageCreate', 'onWindowStageDestroy', 'applyPersonalizationColorMode'].map(name => method(ability, name)).join('\n') +
  '\n}\nglobalThis.Startup = Startup;');
function startupFixture() {
  const f = { callbacks: [], loads: [], applies: [], applyError: undefined };
  const sandbox = {
    DOMAIN: 0, TAG: 'test', hilog: { info() {}, warn() {}, error() {} },
    DiagnosticPrivacy: { formatLogError: () => 'redacted' },
    PersonalizationPreferences: {
      load: dir => { f.loads.push(dir); return { colorMode: 'dark', backgroundBrightness: 52 }; },
      applyColorMode: (ctx, mode) => {
        assert.equal(f.c.appShellContentReady, true);
        f.applies.push({ ctx, mode }); if (f.applyError) throw f.applyError;
      }
    }
  };
  vm.runInNewContext(startupExecutable, sandbox);
  const c = new sandbox.Startup();
  Object.assign(c, {
    context: { filesDir, config: { colorMode: 0 } }, windowStageGeneration: 0,
    appShellContentReady: false, pendingAppShellFeatureActions: [],
    windowEnvironment: { attach() {}, detach() {} }, applyEdgeToEdge() {}, requestNotificationAuthorization() {}
  });
  f.c = c; f.stage = { getMainWindowSync: () => ({}), loadContent: (_path, callback) => f.callbacks.push(callback) };
  return f;
}

test('startup applies saved color only after the current stage finishes loadContent successfully', () => {
  const f = startupFixture(); f.c.onWindowStageCreate(f.stage);
  assert.equal(f.loads.length, 0); assert.equal(f.applies.length, 0);
  f.callbacks[0]({ code: 0 }); assert.deepEqual(f.loads, [filesDir]);
  assert.equal(f.applies.length, 1); assert.equal(f.applies[0].mode, 'dark');
});

test('failed and stale startup callbacks cannot apply color to a replacement window', () => {
  const f = startupFixture(); f.c.onWindowStageCreate(f.stage); f.callbacks[0]({ code: 42 });
  assert.equal(f.loads.length, 0); assert.equal(f.c.appShellContentReady, false);
  f.c.onWindowStageCreate(f.stage); f.c.onWindowStageDestroy(); f.c.onWindowStageCreate(f.stage);
  f.callbacks[1]({ code: 0 }); assert.equal(f.applies.length, 0);
  f.callbacks[2]({ code: 0 }); assert.equal(f.applies.length, 1);
});

test('platform color failure during startup remains contained in the successful page lifecycle', () => {
  const f = startupFixture(); f.applyError = { code: 13 }; f.c.onWindowStageCreate(f.stage);
  assert.doesNotThrow(() => f.callbacks[0]({ code: 0 })); assert.equal(f.c.appShellContentReady, true);
});

test('current appearance controls reach the controller and lifecycle disposal flushes pending choices', () => {
  assert.match(bridge, /\.onSelect\(\(index: number\) => this\.setPersonalizationColorMode\(index\)\)/);
  assert.match(bridge, /onBackgroundBrightnessChange:[\s\S]{0,130}this\.setBackgroundBrightness\(value, mode\)/);
  assert.match(bridge, /\.onChange\(\(value: number\) => this\.setNavigationBottomMargin\(value\)\)/);
  const panel = method(bridge, 'AppearanceSettingsPanel');
  for (const entry of ['ColorModeSettingsPanel', 'HomeLayoutSettingsPanel', 'NavigationMarginSettingsPanel']) {
    assert.ok(panel.includes('this.' + entry + '()'), entry + ' is available in appearance settings');
  }
  const teardown = method(bridge, 'aboutToDisappear');
  assert.ok(teardown.includes('this.lifecycleGeneration++'));
  assert.ok(teardown.includes('this.appShellReady = false'));
  assert.ok(teardown.includes('this.flushPersonalizationPreferences()'));
  assert.ok(teardown.includes('this.flushNavigationMarginPreferences()'));
});
