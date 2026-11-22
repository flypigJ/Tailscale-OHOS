import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8')
  .replace(/^import[\s\S]*?from ['"][^'"]+['"];\s*/gm, '')
  .replace('export default class EntryAbility', 'class EntryAbility');
const flush = () => new Promise(resolve => setImmediate(resolve));

test('synchronous content loading failure leaves the stage unready instead of escaping lifecycle', () => {
  const f = fixture();
  f.stage.loadContent = () => { throw { code: 1300002 }; };
  assert.doesNotThrow(() => f.ability.onWindowStageCreate(f.stage));
  assert.equal(f.ability.appShellContentReady, false);
});

function fixture() {
  const callbacks = [];
  const delivered = [];
  const privacyCalls = [];
  let armed = false;
  const log = { info() {}, warn() {}, error() {} };
  const context = { filesDir: '/private', config: { colorMode: 0 }, eventHub: { emit() {} } };
  const window = {
    setWindowLayoutFullScreen: () => Promise.resolve(),
    setWindowSystemBarEnable: () => Promise.resolve(),
    setWindowSystemBarProperties: () => Promise.resolve(),
    setWindowPrivacyMode: value => { privacyCalls.push(value); return Promise.resolve(); }
  };
  class WindowEnvironment {
    static shellWindowPolicy() { return { edgeToEdge: true, systemBarsVisible: true }; }
    attach() {} detach() {} updateConfiguration() {} setPrivacyMode() {}
  }
  const sandbox = {
    RuntimeDiagnosticService: class { start() {} stop() {} mark() {} },
    ExperimentalBackgroundService: { instance: () => ({ initialize() {}, shutdown() {} }) },
    UIAbility: class { context = context; },
    VpnBackgroundTaskManager: class { register() {} unregister() {} onForeground() {} onBackground() {} },
    AppShellIntentAdapter: class { toFeatureAction() { return { openTaildropInbox: true, taildropNotificationAction: '' }; } },
    AppSecurityPreferences: { isPrivacyProtectionArmedSync: dir => { assert.equal(dir, '/private'); return armed; } },
    WindowEnvironment, hilog: log, DiagnosticPrivacy: { formatLogError: () => 'redacted' },
    ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 1 } },
    notificationManager: { isNotificationEnabled: () => Promise.resolve(true), requestEnableNotification: () => Promise.resolve() },
    CrashDiagnosticService: { initialize() {}, shutdown() {} }, SystemShareInbox: { receive() {} },
    AppStorage: { setOrCreate: (...args) => delivered.push(args) },
    APP_FOREGROUND_EVENT: 'foreground', APP_BACKGROUND_EVENT: 'background'
  };
  vm.runInNewContext(stripTypeScriptTypes(source) + '\nthis.Ability = EntryAbility;', sandbox);
  const ability = new sandbox.Ability();
  const stage = { getMainWindowSync: () => window, loadContent: (_path, cb) => callbacks.push(cb) };
  return { ability, window, stage, callbacks, delivered, privacyCalls, setArmed(value) { armed = value; }, sandbox };
}

test('a destroyed stage cannot be made ready by its late loadContent callback', async () => {
  const f = fixture();
  f.ability.onCreate({}, { launchReason: 0 });
  f.ability.onWindowStageCreate(f.stage);
  f.ability.onWindowStageDestroy();
  f.callbacks[0]({ code: 0 });
  assert.equal(f.ability.appShellContentReady, false);
  assert.equal(f.delivered.length, 0);
  await flush();
});

test('old stage completion cannot drain notification actions into a replacement stage', async () => {
  const f = fixture();
  f.ability.onCreate({}, { launchReason: 0 });
  f.ability.onWindowStageCreate(f.stage);
  f.ability.onWindowStageDestroy();
  f.ability.onWindowStageCreate(f.stage);
  f.callbacks[0]({ code: 0 });
  assert.equal(f.delivered.length, 0);
  f.callbacks[1]({ code: 0 });
  assert.equal(f.delivered.length, 1);
  assert.equal(f.ability.appShellContentReady, true);
  await flush();
});

test('synchronous window failures do not escape a system lifecycle callback or block content loading', async () => {
  const f = fixture();
  f.setArmed(true);
  for (const key of Object.keys(f.window)) f.window[key] = () => { throw { code: 1300002 }; };
  assert.doesNotThrow(() => f.ability.onWindowStageCreate(f.stage));
  assert.equal(f.callbacks.length, 1);
  assert.doesNotThrow(() => f.ability.onConfigurationUpdate({ colorMode: 1 }));
  assert.doesNotThrow(() => f.ability.onForeground());
  await flush();
});

test('armed security protection applies window privacy mode before content loads on cold start and foreground', async () => {
  const unarmed = fixture();
  unarmed.ability.onWindowStageCreate(unarmed.stage);
  assert.deepEqual(unarmed.privacyCalls, []);

  const armed = fixture();
  armed.setArmed(true);
  let privacySetBeforeLoadContent = false;
  armed.stage.loadContent = (_path, cb) => {
    privacySetBeforeLoadContent = armed.privacyCalls.includes(true);
    armed.callbacks.push(cb);
  };
  armed.ability.onWindowStageCreate(armed.stage);
  assert.equal(privacySetBeforeLoadContent, true);
  assert.deepEqual(armed.privacyCalls, [true]);
  armed.ability.onForeground();
  assert.deepEqual(armed.privacyCalls, [true, true]);
  await flush();
});

test('notification query synchronous failure does not prevent page creation', async () => {
  const f = fixture();
  f.sandbox.notificationManager.isNotificationEnabled = () => { throw { code: 1600001 }; };
  assert.doesNotThrow(() => f.ability.onWindowStageCreate(f.stage));
  assert.equal(f.callbacks.length, 1);
  await flush();
});

test('notification query settling after teardown cannot open an authorization prompt', async () => {
  const f = fixture();
  let settle;
  let prompts = 0;
  f.sandbox.notificationManager.isNotificationEnabled = () => new Promise(resolve => { settle = resolve; });
  f.sandbox.notificationManager.requestEnableNotification = async () => { prompts++; };
  f.ability.onWindowStageCreate(f.stage);
  f.ability.onWindowStageDestroy();
  settle(false);
  await flush();
  assert.equal(prompts, 0);
});
