// Exercise the production VPN extension's route summary and delayed config
// recovery without a device, network, credential, or signing file.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(
  process.env.HUAWEI_COMMAND_LINE_TOOLS_HOME || '/Volumes/Doc/Library/Huawei/command-line-tools',
  'hvigor/hvigor/node_modules/typescript'));

function load(relative, globals = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8')
    .replace(/^import[\s\S]*?;\n/gm, '');
  const js = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  }}).outputText;
  const scope = { exports: {}, ...globals };
  vm.runInNewContext(js, scope, { filename: relative });
  return scope.exports;
}

class Clock {
  now = 100000;
  next = 0;
  timers = new Map();
  globals() {
    return {
      Date: { now: () => this.now },
      setTimeout: (fn, ms) => this.add(fn, ms, false),
      clearTimeout: id => this.timers.delete(id),
      setInterval: (fn, ms) => this.add(fn, ms, true),
      clearInterval: id => this.timers.delete(id)
    };
  }
  add(fn, ms, repeat) {
    const id = ++this.next;
    this.timers.set(id, { fn, ms, repeat, at: this.now + ms });
    return id;
  }
  async advance(ms) {
    const end = this.now + ms;
    for (;;) {
      await flush();
      const pending = [...this.timers].filter(([, value]) => value.at <= end)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (!pending) break;
      const [id, timer] = pending;
      this.now = timer.at;
      if (timer.repeat) timer.at += timer.ms;
      else this.timers.delete(id);
      timer.fn();
    }
    this.now = end;
    await flush();
  }
}

async function flush() { for (let i = 0; i < 15; i++) await Promise.resolve(); }
function deferred() {
  let resolve;
  const promise = new Promise(value => { resolve = value; });
  return { promise, resolve };
}

function extension(nativeBridge = {}, clock = new Clock()) {
  const C = load('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', {
    ...clock.globals(),
    VpnExtensionAbility: class {},
    VpnBackgroundTaskManager: class {},
    VpnNetworkMonitor: class {},
    hilog: { info() {}, warn() {}, error() {} },
    nativeBridge,
    VpnStatusHealth: class {},
    NetworkRecoveryCoordinator: class {},
    NetworkRecoveryHealth: class {},
    VpnAccountSnapshotStore: { clear() {}, save() {} },
    DiagnosticEventStore: class {},
    ControlServerConfig: { load: () => ({ confirmed: true, controlURL: 'https://control.invalid' }) },
    DeviceNameService: { model: () => 'test-device' },
    deviceInfo: { majorVersion: 5, seniorVersion: 0, osFullName: '', displayVersion: '' },
    fileIo: { accessSync: () => false },
    vpnExtension: {},
    connection: {}
  }).default;
  const vpn = new C();
  vpn.context = { filesDir: '/test' };
  vpn.recordDiagnosticEvent = () => {};
  return { vpn, clock };
}

function route(address, prefixLength, isDefaultRoute = false, family = 1) {
  return {
    interface: 'vpn-tun', destination: { address: { address, family }, prefixLength },
    gateway: { address: family === 2 ? '' : '0.0.0.0', family },
    hasGateway: false, isDefaultRoute
  };
}

test('VPN config summary counts subnet routes and records creation time without prefixes', () => {
  const clock = new Clock();
  const { vpn } = extension({}, clock);
  let summary = '';
  vpn.writeTextFile = (_path, text) => { summary = text; };
  vpn.writeVpnConfigSummary({
    addresses: [{ address: { address: '100.64.0.2', family: 1 }, prefixLength: 32 }],
    routes: [
      route('100.64.0.0', 10),
      route('fd7a:115c:a1e0::', 48, false, 2),
      route('192.168.2.0', 24),
      route('0.0.0.0', 0, true)
    ],
    isIPv4Accepted: true, isIPv6Accepted: false, mtu: 1280
  });
  assert.match(summary, /addressCount=1/);
  assert.match(summary, /routeCount=4/);
  assert.match(summary, /subnetRouteCount=1/);
  assert.match(summary, /createdAtMs=100000/);
  assert.doesNotMatch(summary, /192\.168\.2/);
});

test('documentation-only pre-login route is not counted as an approved subnet', () => {
  const { vpn } = extension();
  let summary = '';
  vpn.writeTextFile = (_path, text) => { summary = text; };
  vpn.writeVpnConfigSummary({
    addresses: [{ address: { address: '192.0.2.1', family: 1 }, prefixLength: 32 }],
    routes: [route('192.0.2.0', 24)],
    isIPv4Accepted: true, isIPv6Accepted: false, mtu: 1280
  });
  assert.match(summary, /subnetRouteCount=0/);
});

test('VPN restore retries a cached failure until delayed live config arrives', async () => {
  const clock = new Clock();
  const live = deferred();
  let calls = 0;
  const { vpn } = extension({
    backendStart: () => 'OK',
    backendVpnConfigAsync: async () => ++calls === 1 ?
      'FAILED | VPN config | cached network map' : live.promise
  }, clock);
  vpn.context = { filesDir: '/test' };
  const restoring = vpn.restoreBackendVpnConfig();
  await flush();
  assert.equal(calls, 1);
  await clock.advance(250);
  assert.equal(calls, 2);
  live.resolve('100.64.0.2|fd7a:115c:a1e0::1|192.168.2.0/24');
  assert.equal(await restoring, '100.64.0.2|fd7a:115c:a1e0::1|192.168.2.0/24');
});

test('VPN restore accepts a fresh live config with zero subnet routes', async () => {
  const { vpn } = extension({
    backendStart: () => 'OK',
    backendVpnConfigAsync: async () => '100.64.0.2|'
  });
  assert.equal(await vpn.restoreBackendVpnConfig(), '100.64.0.2|');
});

test('restore rejects a successful response that arrives after destruction', async () => {
  const clock = new Clock();
  const response = deferred();
  const { vpn } = extension({
    backendStart: () => 'OK',
    backendVpnConfigAsync: () => response.promise
  }, clock);
  const restoring = vpn.restoreBackendVpnConfig();
  await flush();
  vpn.destroying = true;
  response.resolve('100.64.0.2||');
  assert.equal(await restoring, 'FAILED | VPN config | extension stopped');
});

test('destroying during outstanding config prevents TUN creation and zero-subnet config remains valid', async () => {
  const clock = new Clock();
  const response = deferred();
  let creates = 0;
  const { vpn } = extension({}, clock);
  vpn.vpnConnection = { create: async () => { creates++; return 22; } };
  vpn.restoreBackendVpnConfig = () => response.promise;
  const startup = vpn.createProbeTun();
  await flush();
  vpn.destroying = true;
  response.resolve('100.64.0.2|');
  await startup;
  assert.equal(creates, 0);

  let summary = '';
  vpn.destroying = false;
  vpn.writeTextFile = (_path, text) => { summary = text; };
  vpn.writeVpnConfigSummary({
    addresses: [{ address: { address: '100.64.0.2', family: 1 }, prefixLength: 32 }],
    routes: [route('100.64.0.0', 10)], isIPv4Accepted: true,
    isIPv6Accepted: false, mtu: 1280
  });
  assert.match(summary, /subnetRouteCount=0/);
});

test('failed TUN creation does not publish an applied VPN config summary', async () => {
  let summary = '';
  const { vpn } = extension({
    backendStart: () => 'OK',
    backendVpnConfigAsync: async () => '100.64.0.2|192.0.2.2|192.168.2.0/24',
    tunFdProbe: () => 'OK | tun=22'
  });
  vpn.writeTextFile = (_path, text) => { summary = text; };
  vpn.writeStatus = () => {};
  vpn.vpnConnection = { create: async () => { throw new Error('create failed'); } };
  await vpn.createProbeTun();
  assert.equal(summary, '');
});
