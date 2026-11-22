import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/services/VpnDnsObserver.ets', import.meta.url), 'utf8');
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const snapshot = (revision = 1, config = { Proxied: true, Domains: ['private.test'], Routes: { 'private.test.': [] }, Resolvers: [{ Addr: '100.64.0.9' }] }, session = 'a'.repeat(32), state = 'ready') => JSON.stringify({ schemaVersion: 1, session, revision, state, config });
function fixture() {
  const f = { clock: 1000, queue: [], published: [], calls: 0 };
  const sandbox = { Date: { now: () => f.clock } };
  vm.runInNewContext(stripTypeScriptTypes(source.replace(/^export /gm, ''), { mode: 'transform' }) + '\nglobalThis.Observer = VpnDnsObserver;', sandbox);
  f.owner = new sandbox.Observer(() => { f.calls++; const item = f.queue.shift() ?? snapshot(); if (item instanceof Error) throw item; return Promise.resolve(item); }, s => f.published.push(JSON.parse(JSON.stringify(s))));
  f.tick = async () => { f.clock += 5000; await f.owner.refresh(); };
  return f;
}

test('collects live kernel policy and publishes only non-sensitive counts', async () => {
  const f = fixture(); f.owner.start(); await flush();
  assert.equal(f.owner.current().config.Domains[0], 'private.test');
  assert.deepEqual(f.published.at(-1), { schemaVersion: 1, state: 'ready', revision: 1, magicDns: true,
    resolverCount: 1, fallbackResolverCount: 0, splitDomainCount: 1, searchDomainCount: 1, systemDnsApplied: false });
  assert.doesNotMatch(JSON.stringify(f.published), /private\.test|100\.64|session|Addr/);
  const copy = f.owner.current(); copy.config.Domains.push('mutation.test');
  assert.equal(f.owner.current().config.Domains.length, 1);
});
test('is single-flight and throttles polling independently of heartbeat', async () => {
  const f = fixture(), gate = deferred(); f.queue.push(gate.promise); f.owner.start();
  await f.tick(); await f.owner.refresh(); assert.equal(f.calls, 1);
  gate.resolve(snapshot()); await flush(); await f.owner.refresh(); assert.equal(f.calls, 2);
  await f.owner.refresh(); assert.equal(f.calls, 2);
});
test('stop clears policy and rejects late success and failure', async () => {
  for (const reject of [false, true]) {
    const f = fixture(), gate = deferred(); f.queue.push(gate.promise); f.owner.start(); f.owner.stop();
    if (reject) gate.reject(Error('private failure')); else gate.resolve(snapshot());
    await flush(); assert.equal(f.owner.current(), undefined); assert.equal(f.published.at(-1).state, 'stopped');
  }
});
test('old instance completion cannot clear busy or replace a restarted owner', async () => {
  const f = fixture(), old = deferred(), fresh = deferred(); f.queue.push(old.promise, fresh.promise);
  f.owner.start(); f.owner.stop(); f.owner.start(); old.resolve(snapshot()); await flush();
  await f.tick(); assert.equal(f.calls, 2);
  fresh.resolve(snapshot(1, {}, 'b'.repeat(32))); await flush();
  assert.equal(f.owner.current().session, 'b'.repeat(32));
});
test('accepts new revisions, ignores rollback and rejects another backend session', async () => {
  const f = fixture(); f.owner.start(); await flush(); f.queue.push(snapshot(3, { Domains: ['new.test'] })); await f.tick();
  f.queue.push(snapshot(2)); await f.tick(); assert.equal(f.owner.current().revision, 3);
  f.queue.push(snapshot(99, {}, 'b'.repeat(32))); await f.tick();
  assert.equal(f.owner.current(), undefined); assert.equal(f.published.at(-1).state, 'session_changed');
});
test('unavailable and malformed results clear raw policy and retry later', async () => {
  for (const value of [snapshot(2, null, 'a'.repeat(32), 'unavailable'), 'invalid json',
    snapshot(2, { Routes: { 'private.test': 'invalid' } }), snapshot(2, { Resolvers: [null] }),
    snapshot(2, { Domains: ['x'.repeat(254)] }), snapshot(2, { Proxied: 'true' }),
    snapshot(2, { Resolvers: Array.from({ length: 65 }, () => ({ Addr: '1.1.1.1' })) }),
    snapshot(2, {} , 'bad'), 'x'.repeat(300000), new Error('private error')]) {
    const f = fixture(); f.owner.start(); await flush(); f.queue.push(value); await f.tick();
    assert.equal(f.owner.current(), undefined); assert.equal(f.published.at(-1).state, 'unavailable');
    f.queue.push(snapshot(3)); await f.tick(); assert.equal(f.owner.current().state, 'ready');
  }
});
test('publisher I/O failures cannot interrupt lifecycle or queries', async () => {
  const f = fixture(); f.owner.publish = () => { throw Error('disk full'); };
  assert.doesNotThrow(() => f.owner.start()); await flush(); assert.equal(f.owner.current().state, 'ready');
  assert.doesNotThrow(() => f.owner.stop()); assert.equal(f.owner.current(), undefined);
});
test('a null split-route resolver list retains upstream built-in resolver semantics', async () => {
  const f = fixture(); f.queue.push(snapshot(1, { Routes: { 'private.test': null } }));
  f.owner.start(); await flush();
  assert.equal(f.owner.current().config.Routes['private.test'], null);
  assert.equal(f.published.at(-1).splitDomainCount, 1);
});
test('D1 never applies DNS, persists raw policy, or changes pre-existing bridge contracts', () => {
  const extension = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
  assert.match(extension, /dnsAddresses: \[\],\s*searchDomains: \[\]/);
  assert.match(extension, /vpn-dns-observation\.json`, JSON\.stringify\(summary\)/);
  assert.doesNotMatch(source, /fileIo|nativeBridge|vpnExtension|console\./);
  for (const method of ['onDestroy', 'stopVpnAndBackend', 'stopCancelledStartup', 'destroyProbeTun']) {
    const body = extension.match(new RegExp('^  (?:private (?:async )?)?' + method + '\\([\\s\\S]*?^  }', 'm'))?.[0];
    assert.ok(body?.includes('this.dnsObserver.stop()'), method);
  }
});

test('propagates systemDnsApplied only when state is ready and republishes immediately on status change', async () => {
  let applied = false;
  const f = { clock: 1000, queue: [], published: [] };
  const sandbox = { Date: { now: () => f.clock } };
  vm.runInNewContext(stripTypeScriptTypes(source.replace(/^export /gm, ''), { mode: 'transform' }) + '\nglobalThis.Observer = VpnDnsObserver;', sandbox);
  const observer = new sandbox.Observer(
    () => Promise.resolve(f.queue.shift() ?? snapshot()),
    s => f.published.push(JSON.parse(JSON.stringify(s))),
    () => applied
  );

  applied = true;
  observer.start();
  assert.equal(f.published[0].state, 'pending');
  assert.equal(f.published[0].systemDnsApplied, false, 'pending state must never claim systemDnsApplied');
  await flush();
  assert.equal(f.published.at(-1).state, 'ready');
  assert.equal(f.published.at(-1).systemDnsApplied, true);

  applied = false;
  observer.republish();
  assert.equal(f.published.at(-1).state, 'ready');
  assert.equal(f.published.at(-1).systemDnsApplied, false);

  applied = true;
  observer.republish();
  assert.equal(f.published.at(-1).systemDnsApplied, true);

  f.queue.push('invalid-json');
  f.clock += 5000;
  await observer.refresh();
  assert.equal(f.published.at(-1).state, 'unavailable');
  assert.equal(f.published.at(-1).systemDnsApplied, false);

  observer.stop();
  assert.equal(f.published.at(-1).state, 'stopped');
  assert.equal(f.published.at(-1).systemDnsApplied, false);
});

test('PhysicalDnsService.read returns empty resolvers on zero-DHCP or Quad100-only links while still rejecting invalid networks', async () => {
  const physicalSource = readFileSync(new URL('../entry/src/main/ets/services/PhysicalDnsService.ets', import.meta.url), 'utf8');
  let beforeId = 12, afterId = 12, dnses = [];
  const sandbox = {
    connection: {
      getDefaultNet: async () => ({ netId: beforeId }),
      getConnectionProperties: async () => {
        const props = { dnses };
        beforeId = afterId;
        return props;
      }
    }
  };
  const js = stripTypeScriptTypes(physicalSource.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, ''));
  vm.runInNewContext(js + '\nglobalThis.PhysicalDnsService = PhysicalDnsService;', sandbox);

  // Zero DHCP resolvers and Quad100-only resolvers return empty list instead of throwing.
  const normalize = v => JSON.parse(JSON.stringify(v));
  dnses = [];
  assert.deepEqual(normalize(await sandbox.PhysicalDnsService.read()), { networkId: 12, resolvers: [] });
  dnses = [{ address: '100.100.100.100' }, { address: 'fd7a:115c:a1e0::53' }];
  assert.deepEqual(normalize(await sandbox.PhysicalDnsService.read()), { networkId: 12, resolvers: [] });

  // Deduplicates valid resolvers.
  dnses = [{ address: '192.0.2.53' }, { address: '192.0.2.53' }, { address: '100.100.100.100' }];
  assert.deepEqual(normalize(await sandbox.PhysicalDnsService.read()), { networkId: 12, resolvers: ['192.0.2.53'] });

  // Rejects netId === 0, network change mid-read, and > 64 resolvers.
  beforeId = 0; afterId = 0;
  await assert.rejects(sandbox.PhysicalDnsService.read(), /network unavailable/);
  beforeId = 12; afterId = 13;
  await assert.rejects(sandbox.PhysicalDnsService.read(), /network changed/);
  beforeId = 12; afterId = 12;
  dnses = Array.from({ length: 65 }, (_, i) => ({ address: `198.51.100.${i}` }));
  await assert.rejects(sandbox.PhysicalDnsService.read(), /resolvers unavailable/);
});

test('createProbeTun degrades gracefully to a running VPN tunnel when PhysicalDnsService returns zero resolvers', async () => {
  const extensionSource = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
  const extract = name => {
    const m = new RegExp('^  private (?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm').exec(extensionSource);
    assert.ok(m, name);
    return m[0];
  };
  const dnsStatuses = [], visibleStatuses = [], stageCalls = [];
  const sandbox = {
    BUNDLE_NAME: 'io.github.tailscaleohos', DOMAIN: 0, TAG: 'Test', VPN_EXISTS_ERROR_CODE: 2203002,
    ControlServerConfig: { load: () => ({ confirmed: true, controlURL: 'https://controlplane.tailscale.com' }) },
    ControlServerPresets: { ensure: () => ({ servers: [] }) },
    AccountProfiles: { token: () => 'default:0' },
    TailnetDnsPreferences: { enabled: () => true },
    DnsSettingsStore: {
      load: () => ({ enabled: false, primary: '', secondary: '', searchDomains: [] }),
      upstreams: () => []
    },
    PhysicalDnsService: { read: async () => ({ networkId: 5, resolvers: [] }) },
    DnsRuntimeService: {
      stage: async (...args) => { stageCalls.push(args); },
      read: async () => { throw new Error('waitForDnsSystemPlan must not be called on zero physical resolvers'); },
      sameConfiguration: () => true
    },
    hilog: { info() {}, error() {} },
    nativeBridge: {
      tunFdProbe: () => 'OK',
      backendRestartWithTunAsync: async () => 'OK | state=Running | tun=true',
      backendPeerProbeAsync: async () => 'OK'
    }
  };
  const cls = stripTypeScriptTypes('class Ext {\n' +
    ['createProbeTun', 'writeDnsSystemStatus'].map(extract).join('\n') +
    '\n}\nglobalThis.Ext = Ext;');
  vm.runInNewContext(cls, sandbox);

  let republished = 0;
  const ext = new sandbox.Ext();
  Object.assign(ext, {
    context: { filesDir: '/files' },
    serverControlURL: 'https://controlplane.tailscale.com',
    serverProfileToken: 'default:0',
    serverStateRoot: '/files/tailscale',
    vpnConnection: { protectProcessNet: async () => {}, destroy: async () => {} },
    tunFd: -1,
    destroying: false,
    explicitStopRequested: false,
    backendStopInFlight: false,
    dnsRecoverWithoutTailnetDns: false,
    dnsSystemApplied: false,
    dnsObserver: { stop() {}, republish: () => { republished++; } },
    networkMonitor: { start() {} },
    startupIntentAllowed: () => true,
    stopCancelledStartup: async () => false,
    restoreBackendVpnConfig: async () => '100.64.0.2|fd7a:115c:a1e0::2',
    createTunWithConflictReplacement: async () => 7,
    requestUiBackendHandoff: async () => 'OK',
    deviceModel: () => 'Phone',
    harmonyOSHostinfoVersion: () => '6.0',
    waitForVpnBackend: async (s) => s,
    startStatusUpdates: () => {},
    writePeerStatus: () => {},
    writeVpnConfigSummary: () => {},
    recordDiagnosticEvent: () => {},
    writeStatus: (s) => visibleStatuses.push(s),
    writeAtomicTextFile: (path, text) => {
      if (path.endsWith('/vpn-dns-system-status.json')) {
        dnsStatuses.push(JSON.parse(text));
      }
    }
  });

  await ext.createProbeTun();
  assert.equal(ext.tunFd, 7);
  assert.deepEqual(JSON.parse(JSON.stringify(stageCalls)), [[false, [], [], []]]);
  assert.equal(ext.dnsSystemPlan, undefined);
  assert.ok(visibleStatuses.some((s) => s.includes('state=Running')));
  assert.deepEqual(dnsStatuses.at(-1), {
    schemaVersion: 1,
    state: 'unavailable',
    systemDnsApplied: false,
    dnsAddressCount: 0,
    searchDomainCount: 0
  });
  assert.equal(republished, 0);
});
