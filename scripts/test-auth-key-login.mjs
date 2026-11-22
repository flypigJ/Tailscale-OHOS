import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const shell = read('entry/src/main/ets/components/BridgeStatus.ets');
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const compile = text => stripTypeScriptTypes(text, { mode: 'transform' });
function fixture() {
  const sandbox = {
    $r: x => x, setTimeout, clearTimeout,
    fileIo: {}, nativeBridge: {}, vpnExtension: {}, connection: {}
  };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/ControlServerPresets',
    'services/AccountProfiles',
    'services/DeviceNameService',
    'services/AuthKeyLogin',
    'services/VpnAutoRecovery',
    'services/HomeReadOnlyGateway',
    'services/NetworkSettingsGateway',
    'services/SettingsPreferencesGateway'
  ], sandbox);
  const gwRaw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  vm.runInContext(
    `${compile(gwRaw)}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    sandbox
  );
  loadEtsModules(['services/VpnSessionController'], sandbox);
  const statusMethod = shell.match(/^  private authKeyStatusText\([\s\S]*?^  \}/m)?.[0];
  assert.ok(statusMethod, 'authKeyStatusText');
  const statusScope = { $r: sandbox.$r };
  vm.runInNewContext(compile(statusMethod.replace(/^  private /, 'function ')) + '\nglobalThis.fn = authKeyStatusText;', statusScope);

  const request = deferred(); const submissions = [];
  const state = {
    loginInProgress: false, controlServerConfirmed: true, controlServerURL: sandbox.DEFAULT_CONTROL_SERVER_URL,
    controlServerSwitching: false, hasAuthenticatedSession: false,
    authKeyInput: '  tskey-auth-fake_test_key  ', authKeyLoginVisible: true, authKeyStatus: '',
    loginHandoffStatus: 'Secure Login Pending', appLockRequired: false
  };
  const host = {
    getFilesDir: () => '/files', getCacheDir: () => '/cache', getLifecycleGeneration: () => 1,
    isAppShellReady: () => true, isAppLockRequired: () => state.appLockRequired,
    isLogoutInProgress: () => false, isDiagnosticActionInProgress: () => false, isCacheClearInProgress: () => false,
    isTaildropSendActive: () => false, isTaildropReceiveInProgress: () => false,
    isTaildropMediaSaveInProgress: () => false, shouldPollHealthFast: () => false,
    getBackendStatus: () => 'OK | state=NeedsLogin', setBackendStatus() {},
    getVpnStatus: () => 'Stopped', setVpnStatus() {},
    isBackendReady: () => true, setBackendReady() {}, isBackendInitializationVisible: () => false, setBackendInitializationVisible() {},
    setDevicesLoading() {}, hasAuthenticatedSession: () => state.hasAuthenticatedSession,
    setHasAuthenticatedSession: v => { state.hasAuthenticatedSession = v; },
    isConnectInProgress: () => false, setConnectInProgressState() {},
    isDisconnectInProgress: () => false, setDisconnectInProgress() {},
    isLoginInProgress: () => state.loginInProgress, setLoginInProgress: v => { state.loginInProgress = v; },
    getLoginHandoffStatus: () => state.loginHandoffStatus, setLoginHandoffStatus: s => { state.loginHandoffStatus = s; },
    setLoginPromptKind() {},
    isAuthKeyLoginVisible: () => state.authKeyLoginVisible, setAuthKeyLoginVisible: v => { state.authKeyLoginVisible = v; },
    getAuthKeyInput: () => state.authKeyInput, setAuthKeyInput: v => { state.authKeyInput = v; },
    getAuthKeyStatus: () => state.authKeyStatus, setAuthKeyStatus: v => { state.authKeyStatus = v; },
    isControlServerConfirmed: () => state.controlServerConfirmed, setControlServerConfirmed: v => { state.controlServerConfirmed = v; },
    getControlServerURL: () => state.controlServerURL, setControlServerURL: v => { state.controlServerURL = v; },
    setControlServerInput() {}, setControlServerStatus() {}, setControlServerEditorVisible() {}, setControlServerPresets() {},
    isControlServerSwitching: () => state.controlServerSwitching, setControlServerSwitching: v => { state.controlServerSwitching = v; },
    getAccountProfileId: () => 'default', setAccountProfileId() {}, getAccountProfiles: () => [], setAccountProfiles() {},
    setAccountProfileStatus() {}, getPeers: () => [], onPeersUpdated() {}, onPeerPresenceInvalidated() {},
    setMeshArcReceiver() {}, setAccountSummary() {}, setAvatarLoadFailed() {}, getExitNodes: () => [], setExitNodes() {},
    isExitNodeUpdateInProgress: () => false, setExitNodeUpdateInProgress() {}, isExitNodeStatusFailed: () => false,
    setExitNodeNoneStatus() {}, setExitNodeSelectedStatus() {}, setExitNodeUnavailableStatus() {}, setExitNodeRawStatus() {},
    getNetworkSettings: () => ({ routeAll: true, exitNodeAllowLANAccess: false }), setNetworkSettings() {}, setNetworkSettingStatus() {},
    isRouteAllUpdateInProgress: () => false, setRouteAllUpdateInProgress() {},
    isExitNodeLanUpdateInProgress: () => false, setExitNodeLanUpdateInProgress() {},
    setTrafficDownloadBytes() {}, setTrafficUploadBytes() {}, setTrafficDownloadRate() {}, setTrafficUploadRate() {},
    getTrafficSamples: () => [], setTrafficSamples() {}, isVpnConflictDialogVisible: () => false,
    setVpnConflictDialogVisible() {}, showVpnConflictAlertDialog() {}, syncHomeTitleCompact() {}, setHomeTitleCompact() {},
    deviceModel: () => 'Test', harmonyOSHostinfoVersion: () => '6.0', openControlServerSettings() {},
    openSecureLoginBrowser: async () => {}, confirmControlServerSelection: () => undefined, invalidateAccountGuard() {},
    clearControlServerShellState() {}, reloadTaildropStorageForActiveIdentity() {}, resetTaildropSnapshot() {},
    applyBackendTaildropSnapshot() {}, onLiveExtensionTick() {}, resetStreamingStatesForDisconnect() {},
    autoProbeConnectedPeerServices() {}, syncOfflinePeerStatusRefreshPolling() {}, syncWindowPrivacyMode() {},
    logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1, recordDiagnosticEvent() {}
  };
  const vpnCommandStateMachine = new sandbox.VpnCommandStateMachine();
  const ctrl = new sandbox.VpnSessionController(host, {
    vpnCommandStateMachine,
    vpnCommandGateway: {
      backendStatusAsync: async () => 'OK | state=NeedsLogin',
      loginWithAuthKey: key => { submissions.push(key); return request.promise; }
    }
  });
  ctrl.refreshBackendStatus = async () => {};
  state.vpnCommandStateMachine = vpnCommandStateMachine;
  state.submitAuthKeyLogin = () => ctrl.submitAuthKeyLogin();
  state.toggleAuthKeyLogin = () => ctrl.toggleAuthKeyLogin();
  state.authKeyStatusText = statusScope.fn;
  Object.defineProperty(state, 'backendRestartPromise', {
    get: () => ctrl.backendRestartPromise,
    set: v => { ctrl.backendRestartPromise = v; }
  });
  return { state, ctrl, sandbox, request, submissions };
}

test('device key validation distinguishes management credentials and custom servers', () => {
  const { sandbox } = fixture(); const validate = sandbox.AuthKeyLogin.validationError;
  assert.equal(validate(' \n ', false), 'empty');
  assert.equal(validate(' tskey-auth-fake_key \r\n', false), '');
  assert.equal(validate('tskey-api-example', true), 'management_key');
  assert.equal(validate('tskey-client-example', false), 'management_key');
  for (const key of ['tskey-auth-', 'tskey-unknown-key', 'tskey-auth-a\0b', 'tskey-auth-a b', 'file:/key', 'a'.repeat(4097)]) {
    assert.equal(validate(key, true), 'invalid');
  }
  assert.equal(validate('headscale-key', false), 'invalid');
  assert.equal(validate('headscale-key', true), '');
});

test('submission clears input immediately, submits once and completes after native authentication', async () => {
  const { state, request, submissions } = fixture();
  const result = state.submitAuthKeyLogin();
  assert.equal(state.authKeyInput, ''); assert.equal(state.loginInProgress, true);
  await tick(); await state.submitAuthKeyLogin();
  assert.deepEqual(submissions, ['tskey-auth-fake_test_key']);
  request.resolve('OK | auth key | authenticated'); await result;
  assert.equal(state.authKeyStatus, 'authenticated'); assert.equal(state.authKeyLoginVisible, false);
  assert.equal(state.loginInProgress, false); assert.equal(state.vpnCommandStateMachine.currentState(), 'running');
});

test('approval, rejection, timeout and unexpected errors expose only local messages', async () => {
  for (const [response, expected] of [
    ['OK | auth key | needs_approval', 'needs_approval'],
    ['FAILED | auth key | rejected', 'rejected'],
    ['FAILED | auth key | timeout', 'timeout'],
    ['secret remote error tskey-auth-do_not_echo', 'failed']
  ]) {
    const { state, request, submissions } = fixture();
    const result = state.submitAuthKeyLogin(); await tick(); request.resolve(response); await result;
    assert.equal(state.authKeyStatus, expected); assert.equal(state.authKeyInput, '');
    assert.equal(state.loginInProgress, false); assert.equal(submissions.length, 1);
    assert.doesNotMatch(state.authKeyStatusText(), /do_not_echo|remote error/);
  }
  const { state, request } = fixture();
  const result = state.submitAuthKeyLogin(); await tick(); request.reject(new Error('tskey-auth-do_not_echo')); await result;
  assert.equal(state.authKeyStatus, 'failed'); assert.equal(state.loginInProgress, false);
});

test('restart and lifecycle changes cannot submit a stale key or apply a stale completion', async () => {
  const { state, request, submissions } = fixture(); const restart = deferred();
  state.backendRestartPromise = restart.promise;
  const result = state.submitAuthKeyLogin(); await tick(); assert.equal(submissions.length, 0);
  state.vpnCommandStateMachine.invalidateLifecycle(); restart.resolve(); await result;
  assert.equal(submissions.length, 0); assert.equal(state.authKeyInput, '');
  const second = fixture();
  const completion = second.state.submitAuthKeyLogin(); await tick();
  second.state.vpnCommandStateMachine.invalidateLifecycle();
  second.state.authKeyStatus = 'new lifecycle';
  second.request.resolve('OK | auth key | authenticated'); await completion;
  assert.equal(second.state.authKeyStatus, 'new lifecycle');
});

test('invalid input and app lock do not send credentials; cancel clears the draft', async () => {
  const { state, submissions } = fixture();
  state.authKeyInput = 'tskey-api-admin_token'; await state.submitAuthKeyLogin();
  assert.equal(state.authKeyStatus, 'management_key'); assert.equal(submissions.length, 0);
  state.authKeyInput = 'tskey-auth-key'; state.appLockRequired = true;
  await state.submitAuthKeyLogin(); assert.equal(submissions.length, 0);
  state.appLockRequired = false; state.toggleAuthKeyLogin();
  assert.equal(state.authKeyInput, ''); assert.equal(state.authKeyLoginVisible, false);
});

test('diagnostics redact bare Tailscale credentials and named custom-server keys', () => {
  const { sandbox } = fixture();
  for (const value of ['tskey-auth-private_key', 'tskey-api-private_key', 'tskey-client-private_key',
    'authKey=private_key', 'access_key:private_key']) {
    assert.doesNotMatch(sandbox.DiagnosticPrivacy.redactForLog(value), /private_key/);
  }
});

test('native password field and bilingual resource keys are wired without persistence', () => {
  const form = shell.slice(shell.indexOf('  private AuthKeyLoginForm()'), shell.indexOf('  private AccountDetailRow('));
  const field = read('entry/src/main/ets/components/AccountTextField.ets');
  assert.match(form, /password: true/); assert.match(form, /value: \$authKeyInput/);
  assert.match(field, /this.password \? InputType.Password : InputType.Normal/);
  assert.match(field, /enableAutoFill\(false\)/);
  assert.match(field, /this.password \? CopyOptions.None : CopyOptions.LocalDevice/);
  const refs = [...shell.matchAll(/app\.string\.(auth_key_\w+)/g)].map(match => match[1]);
  for (const locale of ['base', 'zh_CN']) {
    const strings = JSON.parse(read(`entry/src/main/resources/${locale}/element/string.json`)).string;
    const names = strings.map(item => item.name);
    assert.equal(names.length, new Set(names).size);
    for (const ref of refs) assert.ok(strings.find(item => item.name === ref)?.value, `${locale}: ${ref}`);
  }
  assert.doesNotMatch(read('entry/src/main/ets/services/SettingsPreferencesGateway.ets'), /authKeyInput|auth_key_login/);
});
