import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const read = file => readFileSync(new URL('../' + file, import.meta.url), 'utf8').replace(/\r\n/g, '\n');
const native = read('entry/src/main/ets/components/NativeSettingsNavigation.ets');
const bridge = read('entry/src/main/ets/components/BridgeStatus.ets');
const service = read('entry/src/main/ets/services/AnimationPreferences.ets')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');
const motion = read('entry/src/main/ets/components/MotionTokens.ets')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');
function method(name, source = native) {
  const start = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(start, 'production method ' + name);
  const end = source.indexOf('\n  }', start.index);
  assert.ok(end > start.index, name + ' closing brace');
  return source.slice(start.index, end + 4);
}
function listener(name) {
  const start = native.indexOf('  private ' + name + ':');
  assert.ok(start >= 0, 'production listener ' + name);
  const end = native.indexOf('\n  };', start);
  assert.ok(end > start, name + ' closing brace');
  return native.slice(start, end + 5);
}
const methods = ['currentAnimationSettings', 'applyAnimationSettingsLocally', 'updateAnimationSettings',
  'updateAnimationControl', 'applyPreset', 'animationDurationMs', 'canRunPreviewLoop', 'isCurrentPreviewLoop',
  'startPreviewLoop', 'stopPreviewLoop', 'restartPreviewLoop', 'onPreviewVisibilityChanged',
  'schedulePreviewCycle', 'runPreviewCycle', 'aboutToAppear', 'aboutToDisappear', 'onPageNameChanged'];
const executable = stripTypeScriptTypes(service + '\n' + motion + '\nclass Controller {\n' +
  ['appForegroundListener', 'appBackgroundListener'].map(listener).join('\n') + '\n' +
  methods.map(name => method(name)).join('\n') + '\n}\nclass Parent {\n' +
  ['applyAnimationSettings', 'updateAnimationSettings', 'flushAnimationPreferences']
    .map(name => method(name, bridge)).join('\n') + '\n}\n' +
  'globalThis.Controller = Controller;globalThis.Parent = Parent;' +
  'globalThis.Motion = MotionTokens;globalThis.Preferences = AnimationPreferences;');
const plain = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

function fixture() {
  const f = {
    changes: [], animations: [], timers: new Map(), timerHistory: new Map(), nextTimer: 0,
    listeners: new Map(), stored: new Map(), storageFlushes: 0, immediateAnimations: false, animationError: false
  };
  const context = { eventHub: {
    on: (event, callback) => {
      if (!f.listeners.has(event)) f.listeners.set(event, new Set());
      f.listeners.get(event).add(callback);
    },
    off: (event, callback) => f.listeners.get(event)?.delete(callback)
  } };
  const sandbox = {
    SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 },
    APP_FOREGROUND_EVENT: 'foreground', APP_BACKGROUND_EVENT: 'background',
    curves: {
      cubicBezierCurve: (...args) => ({ kind: 'cubic', args }),
      springCurve: (...args) => ({ kind: 'spring', args })
    },
    preferences: { getPreferences: async () => ({
      putSync: (key, value) => f.stored.set(key, value), flush: async () => { f.storageFlushes++; }
    }) },
    setTimeout: (callback, delay) => {
      const id = ++f.nextTimer, timer = { callback, delay };
      f.timers.set(id, timer); f.timerHistory.set(id, timer); return id;
    },
    clearTimeout: id => f.timers.delete(id)
  };
  vm.runInNewContext(executable, sandbox);
  const c = new sandbox.Controller();
  Object.assign(c, {
    pageName: 'animation', glowLevel: 3,
    initialAnimationPreset: 1, initialAnimationDuration: 60, initialAnimationAmplitude: 56, initialAnimationDamping: 64,
    animationPreset: 1, animationDuration: 60, animationAmplitude: 56, animationDamping: 64,
    previewActive: false, previewLoopTimer: -1, previewLoopGeneration: 0, previewLoopRunning: false,
    previewComponentVisible: false, previewInViewport: false, previewAppForeground: true,
    onAnimationSettingsChange: settings => f.changes.push(plain(settings)),
    getUIContext: () => ({ getHostContext: () => context, animateTo: (options, callback) => {
      if (f.animationError) throw Error('renderer unavailable');
      f.animations.push({ options: plain(options), callback });
      if (f.immediateAnimations) callback();
    } })
  });
  const parent = new sandbox.Parent();
  Object.assign(parent, {
    animationPreset: 1, animationDuration: 60, animationAmplitude: 56, animationDamping: 64,
    animationPreferencesSaveTimer: -1, pendingAnimationSettings: undefined,
    getUIContext: () => ({ getHostContext: () => context })
  });
  f.c = c; f.parent = parent; f.motion = sandbox.Motion; f.preferences = sandbox.Preferences;
  f.emit = event => { for (const callback of f.listeners.get(event) ?? []) callback(); };
  f.runTimer = (id = f.timers.keys().next().value) => {
    assert.ok(f.timers.has(id), 'a live timer is available');
    const timer = f.timers.get(id); f.timers.delete(id); timer.callback();
  };
  f.replayTimer = id => { assert.ok(f.timerHistory.has(id)); f.timerHistory.get(id).callback(); };
  f.enter = () => { c.aboutToAppear(); c.onPreviewVisibilityChanged(true); };
  f.connectParent = () => {
    c.onAnimationSettingsChange = settings => {
      f.changes.push(plain(settings)); parent.updateAnimationSettings(settings);
    };
  };
  return f;
}

test('a preset updates its settings and parent immediately, independently of the preview animation callback', () => {
  const f = fixture(); f.c.applyPreset(0);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: 0, duration: 28, amplitude: 32, damping: 82 });
  assert.deepEqual(f.changes, [{ preset: 0, duration: 28, amplitude: 32, damping: 82 }]);
});

test('a delayed preset preview callback cannot overwrite a later manual setting or re-publish the old preset', () => {
  const f = fixture(); f.enter(); f.c.applyPreset(0); f.runTimer();
  f.c.updateAnimationSettings({ preset: -1, duration: 91, amplitude: 32, damping: 82 }, 1);
  for (const animation of f.animations) animation.callback();
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: -1, duration: 91, amplitude: 32, damping: 82 });
  assert.deepEqual(f.changes.at(-1), { preset: -1, duration: 91, amplitude: 32, damping: 82 });
});

for (const [index, settings] of [
  [0, { preset: 0, duration: 28, amplitude: 32, damping: 82 }],
  [1, { preset: 1, duration: 60, amplitude: 56, damping: 64 }],
  [2, { preset: 2, duration: 78, amplitude: 72, damping: 42 }]
]) test(`preset ${index} synchronizes all three controls before any preview timer runs`, () => {
  const f = fixture(); f.enter(); f.c.applyPreset(index);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), settings);
  assert.deepEqual(f.changes, [settings]); assert.equal(f.animations.length, 0); assert.equal(f.timers.size, 1);
});

test('manual control changes preserve the other latest controls and publish the custom preset immediately', () => {
  const f = fixture(); f.c.applyPreset(2);
  f.c.updateAnimationControl('duration', 37, 1);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: -1, duration: 37, amplitude: 72, damping: 42 });
  f.c.updateAnimationControl('amplitude', 19, 1);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: -1, duration: 37, amplitude: 19, damping: 42 });
  f.c.updateAnimationControl('damping', 91, 2);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: -1, duration: 37, amplitude: 19, damping: 91 });
  assert.deepEqual(f.changes.at(-1), { preset: -1, duration: 37, amplitude: 19, damping: 91 });
});

test('manual controls clamp finite values while invalid controls and presets do not publish changes', () => {
  const f = fixture();
  for (const value of [NaN, Infinity, -Infinity, undefined, '55']) f.c.updateAnimationControl('duration', value, 1);
  f.c.updateAnimationControl('unknown', 20, 1);
  for (const index of [-1, 3, NaN, 1.5, '1']) f.c.applyPreset(index);
  assert.equal(f.changes.length, 0);
  f.c.updateAnimationControl('duration', -10, 1); assert.equal(f.c.animationDuration, 0);
  f.c.updateAnimationControl('amplitude', 200, 1); assert.equal(f.c.animationAmplitude, 100);
  f.c.updateAnimationControl('damping', 65.7, 1); assert.equal(f.c.animationDamping, 66);
});

test('child control changes reach the production parent and live MotionTokens before persistence', async () => {
  const f = fixture(); f.connectParent();
  f.c.applyPreset(0); f.c.updateAnimationControl('amplitude', 69, 1);
  const expected = { preset: -1, duration: 28, amplitude: 69, damping: 82 };
  assert.deepEqual(plain(f.preferences.current()), expected);
  assert.deepEqual(plain(f.parent.pendingAnimationSettings), expected);
  assert.equal(f.parent.animationDuration, 28); assert.equal(f.parent.animationAmplitude, 69);
  assert.equal(f.parent.animationDamping, 82); assert.equal(f.parent.animationPreset, -1);
  assert.equal(f.storageFlushes, 0); assert.equal(f.timers.size, 1);
  f.parent.flushAnimationPreferences(); await settle();
  assert.equal(f.storageFlushes, 1); assert.equal(f.stored.get('animation_amplitude'), 69);
  assert.equal(f.stored.get('animation_duration'), 28); assert.equal(f.stored.get('animation_damping'), 82);
});

test('preview waits for actual visibility and repeated start requests keep a single timer', () => {
  const f = fixture(); f.c.aboutToAppear();
  assert.equal(f.timers.size, 0); assert.equal(f.c.previewLoopRunning, false);
  f.c.onPreviewVisibilityChanged(true); const first = f.c.previewLoopTimer;
  f.c.startPreviewLoop(); f.c.onPreviewVisibilityChanged(true);
  assert.equal(f.timers.size, 1); assert.equal(f.c.previewLoopTimer, first);
  assert.equal(f.listeners.get('foreground').size, 1); assert.equal(f.listeners.get('background').size, 1);
});

test('continuous preview alternates automatically without clicks and owns only its next cycle', () => {
  const f = fixture(); f.immediateAnimations = true; f.enter();
  f.runTimer(); assert.equal(f.c.previewActive, true); assert.equal(f.timers.size, 1);
  f.runTimer(); assert.equal(f.c.previewActive, false); assert.equal(f.timers.size, 1);
  f.runTimer(); assert.equal(f.c.previewActive, true); assert.equal(f.timers.size, 1);
  assert.equal(f.animations.length, 3); assert.equal(f.changes.length, 0, 'preview never republishes settings');
});

for (const reason of ['viewport', 'background', 'page', 'disappear']) {
  test(`${reason} stops preview work and invalidates pending timer and animation callbacks`, () => {
    const f = fixture(); f.enter(); f.runTimer();
    const timer = f.c.previewLoopTimer, animation = f.animations[0].callback, active = f.c.previewActive;
    if (reason === 'viewport') f.c.onPreviewVisibilityChanged(false);
    else if (reason === 'background') f.emit('background');
    else if (reason === 'page') { f.c.pageName = 'background'; f.c.onPageNameChanged(); }
    else f.c.aboutToDisappear();
    assert.equal(f.timers.size, 0); assert.equal(f.c.previewLoopRunning, false);
    f.replayTimer(timer); animation();
    assert.equal(f.timers.size, 0); assert.equal(f.animations.length, 1); assert.equal(f.c.previewActive, active);
    if (reason === 'disappear') {
      assert.equal(f.listeners.get('foreground').size, 0); assert.equal(f.listeners.get('background').size, 0);
    }
  });
}

test('foreground and viewport restoration restart exactly one fresh loop and old work cannot release its timer', () => {
  const f = fixture(); f.enter(); const old = f.c.previewLoopTimer;
  f.emit('background'); f.emit('foreground');
  const fresh = f.c.previewLoopTimer;
  assert.notEqual(fresh, old); assert.equal(f.timers.size, 1);
  f.replayTimer(old); assert.equal(f.c.previewLoopTimer, fresh); assert.equal(f.timers.size, 1);
  f.c.onPreviewVisibilityChanged(false); f.emit('background'); f.emit('foreground');
  assert.equal(f.timers.size, 0, 'offscreen preview stays idle on foreground');
  f.c.onPreviewVisibilityChanged(true); assert.equal(f.timers.size, 1);
});

test('leaving and reentering the component keeps listeners and timers owned by the current visit', () => {
  const f = fixture(); f.enter(); const old = f.c.previewLoopTimer;
  f.c.aboutToDisappear(); f.c.aboutToAppear();
  assert.equal(f.timers.size, 0); assert.equal(f.listeners.get('foreground').size, 1);
  f.c.onPreviewVisibilityChanged(true); const fresh = f.c.previewLoopTimer;
  f.replayTimer(old); assert.equal(f.c.previewLoopTimer, fresh); assert.equal(f.timers.size, 1);
});

test('each cycle reads the latest controls even when a drag has not finished', () => {
  const f = fixture(); f.enter(); f.runTimer();
  assert.equal(f.animations[0].options.duration, f.motion.durationFor(400, 60));
  f.c.updateAnimationControl('duration', 94, 1);
  f.c.updateAnimationControl('amplitude', 22, 1); f.c.updateAnimationControl('damping', 91, 1);
  f.runTimer();
  assert.equal(f.animations[1].options.duration, f.motion.durationFor(400, 94));
  assert.deepEqual(f.animations[1].options.curve,
    plain(f.motion.curveFor({ preset: -1, duration: 94, amplitude: 22, damping: 91 })));
  assert.equal(f.timers.size, 1);
});

test('rapid presets and completed drags replace pending preview work without stacking timers', () => {
  const f = fixture(); f.enter(); const old = f.c.previewLoopTimer;
  f.c.applyPreset(0); f.c.applyPreset(2); f.c.updateAnimationControl('duration', 85, 2);
  assert.equal(f.timers.size, 1); assert.equal(f.animations.length, 0);
  f.replayTimer(old); assert.equal(f.timers.size, 1); assert.equal(f.animations.length, 0);
  f.runTimer(); assert.equal(f.animations.length, 1);
  assert.equal(f.animations[0].options.duration, f.motion.durationFor(400, 85));
});

test('a preview renderer failure stops its loop without rolling back committed controls', () => {
  const f = fixture(); f.enter(); f.c.applyPreset(2); f.animationError = true;
  assert.doesNotThrow(() => f.runTimer());
  assert.equal(f.timers.size, 0); assert.equal(f.c.previewLoopRunning, false);
  assert.deepEqual(plain(f.c.currentAnimationSettings()), { preset: 2, duration: 78, amplitude: 72, damping: 42 });
  assert.deepEqual(f.changes.at(-1), { preset: 2, duration: 78, amplitude: 72, damping: 42 });
});

test('slider labels, values and callbacks use one reactive builder object and the latest control key', () => {
  const slider = method('SliderRow');
  assert.match(slider, /SliderRow\(\$\$: NativeSettingsSliderData\)/);
  assert.match(slider, /Text\(`\$\{Math\.round\(\$\$\.value\)\}%`\)/);
  assert.match(slider, /Slider\(\{ value: \$\$\.value,/);
  const page = method('AnimationPage');
  for (const [key, state] of [['duration', 'animationDuration'], ['amplitude', 'animationAmplitude'], ['damping', 'animationDamping']]) {
    assert.match(page, new RegExp('this\\.SliderRow\\(\\{[\\s\\S]{0,150}value: this\\.' + state +
      '[\\s\\S]{0,220}this\\.updateAnimationControl\\(\'' + key + '\', value, mode\\)'));
  }
  const preview = method('PreviewCard');
  assert.match(preview, /\.onVisibleAreaChange\(\[0, 1\], \(_expanding: boolean, ratio: number\) =>\s*this\.onPreviewVisibilityChanged\(ratio > 0\)\)/);
  assert.match(page, /this\.PreviewCard\(\{ active: this\.previewActive, amplitude: this\.animationAmplitude \}\)/);
});
