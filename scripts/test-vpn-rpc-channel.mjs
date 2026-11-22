import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource,
  stripEtsModuleSyntax
} from './helpers/ets-vm-loader.mjs';

const flushMicrotasks = async (ticks = 16) => {
  for (let i = 0; i < ticks; i++) {
    await Promise.resolve();
  }
};

function extractClassMethod(source, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}\\([\\s\\S]*?^  \\}`, 'm').exec(source);
  assert.ok(match, `expected method ${name} in TailscaleVpnExtensionAbility.ets`);
  return match[0];
}

function extractModuleConst(source, name) {
  const match = new RegExp(`^const ${name}\\b[\\s\\S]*?;`, 'm').exec(source);
  assert.ok(match, `expected const ${name} in TailscaleVpnExtensionAbility.ets`);
  return match[0];
}

test('atomic .tmp -> rename client request and server response writes never expose partial JSON or open IPC targets directly', async () => {
  let nowMs = 1_796_000_000_000;
  const mem = createMemoryFileIo({ shortWriteChunkBytes: 7 });
  const requestTarget = '/files/peer-connectivity-request.json';
  const responseTarget = '/files/peer-connectivity-response.json';
  const targetSnapshots = [];

  const recordVisibleTargets = () => {
    for (const target of [requestTarget, responseTarget]) {
      if (mem.files.has(target)) {
        const content = mem.files.get(target);
        targetSnapshots.push({ target, content });
        if (content.length > 0) {
          assert.doesNotThrow(
            () => JSON.parse(content),
            `target ${target} must never expose partial JSON: ${content}`
          );
        }
      }
    }
  };

  const baseWriteSync = mem.fileIo.writeSync;
  mem.fileIo.writeSync = (fd, data) => {
    const count = baseWriteSync(fd, data);
    recordVisibleTargets();
    return count;
  };

  let server;
  const sandbox = {
    Date: { now: () => nowMs },
    systemDateTime: {
      TimeType: { STARTUP: 0 },
      getUptime: () => nowMs
    },
    fileIo: mem.fileIo,
    setTimeout(resolve, delay) {
      nowMs += delay;
      const env = server.peekRawRequest('/files', 'peer-connectivity-request.json');
      if (env) {
        const parsedReq = JSON.parse(env.rawText);
        server.writeResponse(
          '/files',
          'peer-connectivity-response.json',
          parsedReq.requestId,
          JSON.stringify({ state: 'reachable', reason: '', pathType: 'direct', latencyMs: 4 })
        );
      }
      recordVisibleTargets();
      resolve();
    }
  };

  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    'services/PeerPathService'
  ], sandbox);
  server = new sandbox.VpnExtensionRpcServer();

  // Note: PeerPathService uses writeAtomic without allowPartialWrite; verify normal atomic writes
  // never open target paths directly, while multi-byte UTF-8 payloads round-trip cleanly.
  mem.setShortWriteChunkBytes(null);
  const service = new sandbox.PeerPathService({ filesDir: '/files' });
  const result = await service.probe('peer-0123456789abcdef', true, true);

  assert.equal(result.type, 'direct');
  assert.equal(result.latencyMs, 4);
  assert.ok(targetSnapshots.length > 0);

  const openedPaths = mem.events.filter((e) => e[0] === 'open').map((e) => e[1]);
  assert.ok(openedPaths.length >= 3);
  assert.equal(
    openedPaths.some((p) => p === requestTarget || p === responseTarget),
    false,
    'IPC request/response targets must only be updated via temp-file rename, never direct O_TRUNC open'
  );
  assert.ok(openedPaths.every((p) => p.endsWith('.tmp')));
  assert.equal([...mem.files.keys()].some((p) => p.endsWith('.tmp')), false);
  assert.equal(mem.files.get(responseTarget), '');
});

test('VpnExtensionRpcServer requestId deduplication preserves a newer request renamed onto requestPath right after readTextSync', async () => {
  const nowMs = 1_796_000_010_000;
  const mem = createMemoryFileIo();
  const requestFile = 'taildrive-query-request.json';
  const responseFile = 'taildrive-query-response.json';
  const requestPath = `/files/${requestFile}`;

  // Seed leftover pre-restart files and temp siblings to verify resetAll cleanup.
  mem.files.set(requestPath, JSON.stringify({ requestId: 50, operation: 'list', payload: '{"path":"/stale"}' }));
  mem.files.set(`/files/${responseFile}`, JSON.stringify({ requestId: 50, result: '{"state":"ready"}' }));
  mem.files.set(`${requestPath}.rpc-req.1.1.tmp`, 'orphan-temp');

  let injectedConcurrentRename = false;
  const baseReadTextSync = mem.fileIo.readTextSync;
  mem.fileIo.readTextSync = (path) => {
    const text = baseReadTextSync(path);
    if (path === requestPath && !injectedConcurrentRename && text.includes('"requestId":101')) {
      injectedConcurrentRename = true;
      // Simulate UI process atomically renaming request #102 onto requestPath 1ms after Extension read #101.
      sandbox.AtomicFileStore.writeAtomic(
        requestPath,
        JSON.stringify({ requestId: 102, operation: 'stat', payload: '{"path":"/second"}' }),
        { owner: 'rpc-req', fsync: false }
      );
    }
    return text;
  };

  const dispatched = [];
  const vpnSource = readEtsSource('vpnextensionability/TailscaleVpnExtensionAbility');
  const sandbox = {
    Date: { now: () => nowMs },
    DOMAIN: 0,
    TAG: 'TestVpn',
    hilog: { info() {}, error() {} },
    fileIo: mem.fileIo,
    nativeBridge: {
      backendTaildriveListAsync: async (payload) => {
        dispatched.push({ op: 'list', payload });
        return '{"state":"ready","path":"/first","entries":[],"reason":""}';
      },
      backendTaildriveStatAsync: async (payload) => {
        dispatched.push({ op: 'stat', payload });
        return '{"state":"ready","entry":{"name":"second","path":"/second","kind":"file","size":1,"modifiedAtMs":1},"reason":""}';
      },
      backendTaildriveMutateAsync: async () => '{"state":"ready"}'
    }
  };

  loadEtsModules(['services/AtomicFileStore', 'services/VpnExtensionRpcChannel'], sandbox);
  const harnessCode = [
    extractModuleConst(vpnSource, 'TAILDRIVE_REQUEST_MAX_BYTES'),
    'class VpnRpcHarness {',
    '  context = { filesDir: "/files" };',
    '  destroying = false;',
    '  backendStopInFlight = false;',
    '  dnsInternalRebuild = false;',
    '  taildriveQueryInFlight = false;',
    '  rpcServer = undefined;',
    extractClassMethod(vpnSource, 'ensureRpcServer'),
    extractClassMethod(vpnSource, 'resetRpcChannels'),
    extractClassMethod(vpnSource, 'processTaildriveQueryRequest'),
    extractClassMethod(vpnSource, 'takeTaildriveRequest'),
    extractClassMethod(vpnSource, 'completeTaildriveRequest'),
    extractClassMethod(vpnSource, 'taildriveExtensionFailure'),
    '}',
    'globalThis.VpnRpcHarness = VpnRpcHarness;'
  ].join('\n');
  vm.runInContext(stripEtsModuleSyntax(harnessCode), sandbox);

  const harness = new sandbox.VpnRpcHarness();
  harness.resetRpcChannels();
  assert.equal(mem.files.has(requestPath), false, 'resetRpcChannels must unlink leftover pre-restart request');
  assert.equal(mem.files.has(`/files/${responseFile}`), false, 'resetRpcChannels must unlink leftover response');
  assert.equal(mem.files.has(`${requestPath}.rpc-req.1.1.tmp`), false, 'resetRpcChannels must clean orphan .tmp');

  // Write #101 atomically; reading #101 will race with #102 atomic rename right after readTextSync.
  sandbox.AtomicFileStore.writeAtomic(
    requestPath,
    JSON.stringify({ requestId: 101, operation: 'list', payload: '{"path":"/first"}' }),
    { owner: 'rpc-req', fsync: false }
  );

  harness.processTaildriveQueryRequest();
  assert.equal(injectedConcurrentRename, true);
  assert.equal(dispatched.length, 1);
  assert.deepEqual(dispatched[0], { op: 'list', payload: '{"path":"/first"}' });

  await flushMicrotasks();
  assert.equal(harness.taildriveQueryInFlight, false);
  assert.equal(JSON.parse(mem.files.get(`/files/${responseFile}`)).requestId, 101);

  // Next poll MUST pick up #102 because consuming #101 never truncated requestPath!
  harness.processTaildriveQueryRequest();
  assert.equal(dispatched.length, 2);
  assert.deepEqual(dispatched[1], { op: 'stat', payload: '{"path":"/second"}' });

  await flushMicrotasks();
  assert.equal(JSON.parse(mem.files.get(`/files/${responseFile}`)).requestId, 102);

  // Subsequent poll with #102 still on disk must deduplicate by requestId and NOT re-dispatch #102.
  harness.processTaildriveQueryRequest();
  await flushMicrotasks();
  assert.equal(dispatched.length, 2);
});

test('checkVpnHeartbeat fast-fails a 30-minute Taildrive transfer within 1 poll (< 200ms) on stale heartbeat or state=Stopped', async () => {
  const controlUrl = 'https://controlplane.tailscale.com';
  for (const statusLine of [
    'OK | state=Running | tun=true | heartbeatMs=1795999970000 | snapshotMs=1795999970000',
    'OK | state=Stopped | tun=false | heartbeatMs=1796000000000 | snapshotMs=1796000000000',
    'FAILED | VPN extension startup | code=2200001 | heartbeatMs=1796000000000 | snapshotMs=0',
    'HarmonyOS VPN Extension stopped'
  ]) {
    let nowMs = 1_796_000_000_000;
    let polls = 0;
    const mem = createMemoryFileIo();
    const sandbox = {
      Date: { now: () => nowMs },
      fileIo: mem.fileIo,
      setTimeout(resolve, delay) {
        assert.equal(delay, 100);
        polls++;
        nowMs += delay;
        resolve();
      }
    };
    loadEtsModules([
      'services/AtomicFileStore',
      'services/VpnExtensionRpcChannel',
      'services/ControlServerConfig',
      'services/ControlServerPresets',
      'services/AccountProfiles',
      'services/TaildriveGateway'
    ], sandbox);

    sandbox.ControlServerPresets.ensure('/files', controlUrl);
    sandbox.AccountProfiles.ensure('/files', controlUrl);
    mem.files.set(
      '/files/control-server.json',
      JSON.stringify({ controlURL: controlUrl, confirmed: true, updatedAtMs: 1 })
    );
    mem.files.set('/files/vpn-probe-status.txt', statusLine);

    const gateway = new sandbox.TaildriveGateway();
    gateway.configure({ filesDir: '/files' });

    const startedMs = nowMs;
    await assert.rejects(
      gateway.download({
        requestId: 9001,
        remotePath: '/movies/4k.mkv',
        localRoot: '/cache',
        localPath: '/cache/4k.mkv'
      }),
      /vpn_heartbeat_lost/
    );
    assert.equal(polls, 1, `must abort on first 100ms poll for status: ${statusLine}`);
    assert.ok(nowMs - startedMs < 200, 'elapsed virtual time must be < 200ms instead of 30 minutes');
  }
});

test('startStatusUpdates dispatches processMediaServiceProbeRequest on the 100ms fast loop while backendSnapshot is blocked', async () => {
  let nowMs = 1_796_000_050_000;
  const mem = createMemoryFileIo();
  const timers = new Map();
  const diagnosticEvents = [];
  const vpnSource = readEtsSource('vpnextensionability/TailscaleVpnExtensionAbility');

  const sandbox = {
    Date: { now: () => nowMs },
    DOMAIN: 0,
    TAG: 'TestVpn',
    hilog: { info() {}, error() {} },
    systemDateTime: {
      TimeType: { STARTUP: 0 },
      getUptime: () => nowMs
    },
    fileIo: mem.fileIo,
    PathDiagnosticService: { resume() {}, poll() {} },
    setInterval(cb, delay) {
      timers.set(delay, cb);
      return delay;
    },
    clearInterval() {},
    setTimeout(resolve, delay) {
      nowMs += delay;
      // Trigger the 100ms fast loop while the 1000ms backendSnapshot() remains permanently pending.
      const fastTick = timers.get(100);
      if (fastTick) {
        fastTick();
      }
      resolve();
    },
    nativeBridge: {
      backendSnapshot: () => new Promise(() => {}),
      backendMediaServiceProbeAsync: async (peerKey) => JSON.stringify({
        state: 'available',
        checkedAt: nowMs,
        services: [{
          type: 'jellyfin',
          name: `Media-${peerKey.slice(-4)}`,
          url: 'http://100.64.0.8:8096',
          version: '10.9.0',
          latencyMs: 6
        }]
      })
    }
  };

  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    'services/MediaServiceProbeService'
  ], sandbox);

  const extensionSnippet = [
    'class FastLoopExtension {',
    '  context = { filesDir: "/files" };',
    '  statusTimer = -1;',
    '  taildropRequestTimer = -1;',
    '  taildropIncomingTimer = -1;',
    '  peerSnapshotRequestId = 0;',
    '  peerSnapshotInFlight = false;',
    '  statusUpdateInFlight = false;',
    '  mediaServiceProbeInFlight = false;',
    '  destroying = false;',
    '  backendStopInFlight = false;',
    '  explicitStopRequested = false;',
    '  dnsRebuildInFlight = false;',
    '  dnsInternalRebuild = false;',
    '  pathDiagnosticProtection = 1;',
    '  pathDiagnosticProtectionCode = 0;',
    '  rpcServer = undefined;',
    '  dnsObserver = { start() {}, refresh() {} };',
    '  refreshDeviceSnapshot() {}',
    '  refreshPhysicalDnsBase() {}',
    '  refreshTaildropIncomingNotification() {}',
    '  writeCurrentStatusHeartbeat() {}',
    '  processBackendStopRequest() { return false; }',
    '  processDnsDiagnosticRequest() {}',
    '  processDebugDnsRebuildRequest() {}',
    '  processTaildropSendRequest() {}',
    '  processTaildropCancelRequest() {}',
    '  processTaildropReceiveRequest() {}',
    '  processTaildriveQueryRequest() {}',
    '  processTaildriveTransferRequest() {}',
    '  processTaildriveManualTransferRequest() {}',
    '  processTaildriveControlRequest() {}',
    '  processLocalSendRefreshRequest() {}',
    '  processPeerConnectivityRequest() {}',
    '  processSunshineProbeRequest() {}',
    extractClassMethod(vpnSource, 'ensureRpcServer'),
    extractClassMethod(vpnSource, 'resetRpcChannels'),
    extractClassMethod(vpnSource, 'startStatusUpdates'),
    extractClassMethod(vpnSource, 'processMediaServiceProbeRequest'),
    '}',
    'globalThis.FastLoopExtension = FastLoopExtension;'
  ].join('\n');
  vm.runInContext(stripEtsModuleSyntax(extensionSnippet), sandbox);

  const ext = new sandbox.FastLoopExtension();
  ext.recordDiagnosticEvent = (event, phase) => diagnosticEvents.push([event, phase]);
  ext.startStatusUpdates();

  // Start slow 1000ms snapshot so statusUpdateInFlight stays true indefinitely.
  timers.get(1000)();
  assert.equal(ext.statusUpdateInFlight, true);

  const mediaService = new sandbox.MediaServiceProbeService({ filesDir: '/files' });
  const peerKey = 'peer-fedcba9876543210';
  const [first, coalesced] = await Promise.all([
    mediaService.probe(peerKey, true, false),
    mediaService.probe(peerKey, true, false)
  ]);

  assert.equal(first.state, 'available');
  assert.equal(first.services.length, 1);
  assert.equal(first.services[0].type, 'jellyfin');
  assert.deepEqual(coalesced, first);
  assert.equal(
    diagnosticEvents.filter((e) => e[0] === 'media_probe_started').length,
    1,
    'concurrent non-forced media probes for the same peer must coalesce onto 1 extension RPC'
  );
  assert.equal(ext.statusUpdateInFlight, true, 'media probe completed while backendSnapshot remained blocked');
});

test('CrashDiagnosticService accepts VpnExtensionRpcChannel.ets source frames across capture and archive reload', () => {
  const nowMs = 1_796_000_100_000;
  const mem = createMemoryFileIo();
  const watchers = [];
  const sandbox = {
    Date: { now: () => nowMs },
    setTimeout: () => 1,
    clearTimeout() {},
    fileIo: mem.fileIo,
    hiAppEvent: {
      domain: { OS: 'OS' },
      event: { APP_CRASH: 'APP_CRASH' },
      addWatcher: (watcher) => {
        watchers.push(watcher);
        return {};
      },
      removeWatcher() {}
    }
  };

  loadEtsModules(['services/AtomicFileStore', 'services/CrashDiagnosticService'], sandbox);
  const { CrashDiagnosticService } = sandbox;
  assert.equal(CrashDiagnosticService.enable('/files'), true);

  watchers[0].onReceive('OS', [{
    name: 'APP_CRASH',
    appEventInfos: [{
      domain: 'OS',
      name: 'APP_CRASH',
      params: {
        time: nowMs,
        crash_type: 'JsError',
        foreground: true,
        bundle_version: '1.2.0',
        cpu_abi: 'arm64-v8a',
        exception: {
          name: 'Error',
          stack: [
            '    at request (entry|entry|1.2.0|src/main/ets/services/VpnExtensionRpcChannel.ets:10:5)',
            '    at unapproved (src/main/ets/services/PrivateSecretChannel.ets:10:5)'
          ].join('\n')
        }
      }
    }]
  }]);

  CrashDiagnosticService.shutdown();
  CrashDiagnosticService.initialize('/files');
  const exported = JSON.parse(CrashDiagnosticService.exportSnapshot('/files'));
  assert.equal(exported.records.length, 1);
  assert.deepEqual(exported.records[0].frames, [
    'src/main/ets/services/VpnExtensionRpcChannel.ets:10:5'
  ]);
});

test('client clear or unlink resets lastConsumedRequestIds so a restarted client reusing an earlier requestId is accepted', () => {
  const nowMs = 1_796_000_200_000;
  const mem = createMemoryFileIo();
  const sandbox = {
    Date: { now: () => nowMs },
    fileIo: mem.fileIo
  };
  loadEtsModules(['services/AtomicFileStore', 'services/VpnExtensionRpcChannel'], sandbox);
  const server = new sandbox.VpnExtensionRpcServer();
  const reqFile = 'peer-connectivity-request.json';
  const reqPath = `/files/${reqFile}`;

  // Initial request #500 is consumed once and deduplicated while still present on disk.
  sandbox.AtomicFileStore.writeAtomic(
    reqPath,
    JSON.stringify({ requestId: 500, peerKey: 'peer-0123456789abcdef' }),
    { owner: 'rpc-req', fsync: false }
  );
  assert.equal(server.peekRawRequest('/files', reqFile)?.requestId, 500);
  assert.equal(server.peekRawRequest('/files', reqFile), undefined);

  // Case A: Client clears requestPath to empty ('') after consuming response; idle server tick observes size === 0.
  sandbox.AtomicFileStore.writeAtomic(reqPath, '', { owner: 'rpc-clear', fsync: false });
  assert.equal(server.peekRawRequest('/files', reqFile), undefined);

  // Restarted client reuses earlier requestId #500 (or lower #400): MUST be accepted, not dropped!
  sandbox.AtomicFileStore.writeAtomic(
    reqPath,
    JSON.stringify({ requestId: 500, peerKey: 'peer-0123456789abcdef' }),
    { owner: 'rpc-req', fsync: false }
  );
  assert.equal(server.peekRawRequest('/files', reqFile)?.requestId, 500);

  // Case B: Unlinked requestPath also clears lastConsumedRequestIds.
  mem.fileIo.unlinkSync(reqPath);
  assert.equal(server.peekRawRequest('/files', reqFile), undefined);
  sandbox.AtomicFileStore.writeAtomic(
    reqPath,
    JSON.stringify({ requestId: 500, peerKey: 'peer-0123456789abcdef' }),
    { owner: 'rpc-req', fsync: false }
  );
  assert.equal(server.peekRawRequest('/files', reqFile)?.requestId, 500);

  // Case C: Malformed garbage unlinks file and clears lastConsumedRequestIds so #500 can be reused again.
  sandbox.AtomicFileStore.writeAtomic(reqPath, '{malformed', { owner: 'rpc-req', fsync: false });
  assert.equal(server.peekRawRequest('/files', reqFile)?.parseError, true);
  sandbox.AtomicFileStore.writeAtomic(
    reqPath,
    JSON.stringify({ requestId: 500, peerKey: 'peer-0123456789abcdef' }),
    { owner: 'rpc-req', fsync: false }
  );
  assert.equal(server.peekRawRequest('/files', reqFile)?.requestId, 500);
});

test('requestPath is cleared after ok and timeout so idle peekRawRequest skips readTextSync, without clobbering a newer #102 rename', async () => {
  let nowMs = 1_796_000_300_000;
  const mem = createMemoryFileIo();
  const reqFile = 'sunshine-probe-request.json';
  const respFile = 'sunshine-probe-response.json';
  const reqPath = `/files/${reqFile}`;
  const respPath = `/files/${respFile}`;
  let onPoll = () => {};

  const sandbox = {
    Date: { now: () => nowMs },
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => nowMs },
    fileIo: mem.fileIo,
    setTimeout(resolve, delay) {
      nowMs += delay;
      onPoll();
      resolve();
    }
  };
  loadEtsModules(['services/AtomicFileStore', 'services/VpnExtensionRpcChannel'], sandbox);
  const server = new sandbox.VpnExtensionRpcServer();

  // 1) OK completion clears requestPath so subsequent idle server ticks perform zero readTextSync calls.
  onPoll = () => {
    const env = server.peekRawRequest('/files', reqFile);
    if (env) {
      server.writeResponse('/files', respFile, env.requestId, '{"state":"available"}');
    }
  };
  const okRpc = await sandbox.VpnExtensionRpcChannel.request({
    filesDir: '/files',
    requestFile: reqFile,
    responseFile: respFile,
    requestId: 101,
    requestJson: JSON.stringify({ requestId: 101, peerKey: 'peer-0123456789abcdef' }),
    timeoutMs: 1000,
    pollIntervalMs: 150,
    useMonotonicClock: true
  });
  assert.equal(okRpc.status, 'ok');
  assert.equal(mem.files.get(reqPath), '');

  mem.resetEvents();
  for (let i = 0; i < 5; i++) {
    assert.equal(server.peekRawRequest('/files', reqFile), undefined);
  }
  assert.equal(
    mem.events.some((e) => e[0] === 'read' && e[1] === reqPath),
    false,
    'idle peekRawRequest ticks on cleared requestPath must not invoke fileIo.readTextSync'
  );

  // 2) Timeout also clears requestPath when still owned by the timed-out request.
  onPoll = () => {};
  const timeoutRpc = await sandbox.VpnExtensionRpcChannel.request({
    filesDir: '/files',
    requestFile: reqFile,
    responseFile: respFile,
    requestId: 202,
    requestJson: JSON.stringify({ requestId: 202, peerKey: 'peer-0123456789abcdef' }),
    timeoutMs: 300,
    pollIntervalMs: 150,
    useMonotonicClock: true
  });
  assert.equal(timeoutRpc.status, 'timeout');
  assert.equal(mem.files.get(reqPath), '');

  mem.resetEvents();
  assert.equal(server.peekRawRequest('/files', reqFile), undefined);
  assert.equal(mem.events.some((e) => e[0] === 'read' && e[1] === reqPath), false);

  // 3) Ownership guard: if concurrent client already renamed #102 onto requestPath before #101 finishes,
  //    #101's completion MUST NOT clobber #102!
  const newerPayload = JSON.stringify({ requestId: 102, peerKey: 'peer-fedcba9876543210' });
  onPoll = () => {
    server.writeResponse('/files', respFile, 101, '{"state":"available"}');
    // Simulate a newer request #102 already atomically renamed onto reqPath before #101 cleans up.
    sandbox.AtomicFileStore.writeAtomic(reqPath, newerPayload, { owner: 'rpc-req', fsync: false });
  };
  const guardedOk = await sandbox.VpnExtensionRpcChannel.request({
    filesDir: '/files',
    requestFile: reqFile,
    responseFile: respFile,
    requestId: 101,
    requestJson: JSON.stringify({ requestId: 101, peerKey: 'peer-0123456789abcdef' }),
    timeoutMs: 1000,
    pollIntervalMs: 150,
    useMonotonicClock: true
  });
  assert.equal(guardedOk.status, 'ok');
  assert.equal(mem.files.get(reqPath), newerPayload, '#101 completion must preserve newer #102 request on disk');
  assert.equal(server.peekRawRequest('/files', reqFile)?.requestId, 102);
  assert.equal(mem.files.get(respPath), '');
});

test('duplicate resetRpcChannels across onCreate and startStatusUpdates preserves live requests written after state=Running', () => {
  const nowMs = 1_796_000_400_000;
  const mem = createMemoryFileIo();
  const vpnSource = readEtsSource('vpnextensionability/TailscaleVpnExtensionAbility');
  const timers = new Map();

  const sandbox = {
    Date: { now: () => nowMs },
    DOMAIN: 0,
    TAG: 'TestVpn',
    hilog: { info() {}, error() {} },
    fileIo: mem.fileIo,
    PathDiagnosticService: { resume() {}, poll() {} },
    setInterval(cb, delay) {
      timers.set(delay, cb);
      return delay;
    },
    clearInterval() {},
    nativeBridge: {
      backendSnapshot: () => new Promise(() => {})
    }
  };
  loadEtsModules(['services/AtomicFileStore', 'services/VpnExtensionRpcChannel'], sandbox);

  const snippet = [
    'class StartupRaceExtension {',
    '  context = { filesDir: "/files" };',
    '  statusTimer = -1;',
    '  taildropRequestTimer = -1;',
    '  taildropIncomingTimer = -1;',
    '  peerSnapshotRequestId = 0;',
    '  peerSnapshotInFlight = false;',
    '  statusUpdateInFlight = false;',
    '  destroying = false;',
    '  backendStopInFlight = false;',
    '  explicitStopRequested = false;',
    '  dnsRebuildInFlight = false;',
    '  dnsInternalRebuild = false;',
    '  rpcChannelsInitialized = false;',
    '  rpcServer = undefined;',
    '  vpnConnection = undefined;',
    '  tunFd = -1;',
    '  latestTaildropSnapshot = { transfer: { state: "idle" } };',
    '  runtimeDiagnostic = { stop() {} };',
    '  networkMonitor = { stop() {} };',
    '  dnsObserver = { start() {}, refresh() {}, stop() {} };',
    '  refreshDeviceSnapshot() {}',
    '  refreshTaildropIncomingNotification() {}',
    '  writeDnsSystemStatus() {}',
    '  stopBackendStopWatcher() {}',
    '  finishDestroyedBackend() { return Promise.resolve(); }',
    '  writeTaildropSnapshot() {}',
    '  writeStatus() {}',
    '  recordDiagnosticEvent() {}',
    extractClassMethod(vpnSource, 'ensureRpcServer'),
    extractClassMethod(vpnSource, 'resetRpcChannels'),
    extractClassMethod(vpnSource, 'startStatusUpdates'),
    extractClassMethod(vpnSource, 'onDestroy'),
    '}',
    'globalThis.StartupRaceExtension = StartupRaceExtension;'
  ].join('\n');
  vm.runInContext(stripEtsModuleSyntax(snippet), sandbox);

  const staleReqPath = '/files/taildrive-query-request.json';
  const liveProbePath = '/files/media-service-probe-request.json';
  mem.files.set(staleReqPath, '{"requestId":9,"operation":"list","payload":"{}"}');

  const ext = new sandbox.StartupRaceExtension();
  // Step 1: onCreate invokes resetRpcChannels(), unlinking stale pre-restart files.
  ext.resetRpcChannels();
  assert.equal(mem.files.has(staleReqPath), false);
  assert.equal(ext.rpcChannelsInitialized, true);

  // Step 2: createProbeTun publishes state=Running while waiting for waitForDnsSystemPlan();
  // UI immediately writes live requests before startStatusUpdates() is reached.
  const liveRequest = JSON.stringify({ requestId: 701, operation: 'list', payload: '{"path":"/"}' });
  const liveProbe = JSON.stringify({ requestId: 702, peerKey: 'peer-0123456789abcdef' });
  sandbox.AtomicFileStore.writeAtomic(staleReqPath, liveRequest, { owner: 'rpc-req', fsync: false });
  sandbox.AtomicFileStore.writeAtomic(liveProbePath, liveProbe, { owner: 'rpc-req', fsync: false });

  // Step 3: startStatusUpdates() runs — must NOT re-run resetAll and wipe the live requests!
  ext.startStatusUpdates();
  assert.equal(mem.files.get(staleReqPath), liveRequest);
  assert.equal(mem.files.get(liveProbePath), liveProbe);
  assert.equal(ext.ensureRpcServer().peekRawRequest('/files', 'taildrive-query-request.json')?.requestId, 701);
  assert.equal(ext.ensureRpcServer().peekRawRequest('/files', 'media-service-probe-request.json')?.requestId, 702);

  // Step 4: onDestroy() resets rpcChannelsInitialized so a subsequent session cleans stale files again.
  ext.onDestroy();
  assert.equal(ext.rpcChannelsInitialized, false);
  ext.destroying = false;
  ext.resetRpcChannels();
  assert.equal(mem.files.has(staleReqPath), false);
  assert.equal(mem.files.has(liveProbePath), false);
});
