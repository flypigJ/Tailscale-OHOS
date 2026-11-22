import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource
} from './helpers/ets-vm-loader.mjs';

const REPO_ROOT = new URL('../', import.meta.url);
const readRepoFile = rel => readFileSync(new URL(rel, REPO_ROOT), 'utf8').replace(/\r\n/g, '\n');

function extractMethod(source, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm').exec(source);
  assert.ok(match, `missing method ${name}`);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end > match.index, `missing closing brace for ${name}`);
  return source.slice(match.index, end + 4);
}

const SYNC_RENDER_CALL_PREFIX =
  /(?:\bForEach|\bLazyForEach|\.(?:map|filter|some|every|find|findIndex|forEach|sort|reduce|flatMap))\s*\(\s*$/;

/**
 * Strips deferred UI callback closures (e.g. .onClick(() => ...), component callback props
 * like onSelect: (v) => ..., action: () => ..., and *Button(..., () => ...)) while preserving
 * all synchronous render bodies, ForEach/LazyForEach generators, and array combinators
 * (.map/.filter/.some/.every/.find/.forEach) so we inspect the exact synchronous render
 * call-graph of build() and @Builder methods.
 */
function stripDeferredEventClosures(body) {
  let out = '';
  let i = 0;
  while (i < body.length) {
    const ch = body[i];
    if (ch === '/' && body[i + 1] === '/') {
      while (i < body.length && body[i] !== '\n') {
        i++;
      }
      continue;
    }
    if (ch === '/' && body[i + 1] === '*') {
      i += 2;
      while (i < body.length && !(body[i] === '*' && body[i + 1] === '/')) {
        i++;
      }
      i = Math.min(body.length, i + 2);
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const q = ch;
      out += ch;
      i++;
      while (i < body.length && body[i] !== q) {
        if (body[i] === '\\' && i + 1 < body.length) {
          out += body[i] + body[i + 1];
          i += 2;
          continue;
        }
        out += body[i];
        i++;
      }
      if (i < body.length) {
        out += body[i];
        i++;
      }
      continue;
    }

    const rest = body.slice(i);
    const arrowMatch = /^(?:\([^()]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*(?::\s*[A-Za-z0-9_<>\[\]\s|]+)?=>/.exec(rest);
    if (arrowMatch) {
      // Check if this arrow is an argument to ForEach / LazyForEach / array method:
      // Walk backwards in `out` to find the enclosing `(` of the call argument list.
      let p = out.length - 1;
      let parenDepth = 0;
      let braceDepth = 0;
      while (p >= 0) {
        const c = out[p];
        if (c === ')') parenDepth++;
        else if (c === '(') {
          if (parenDepth === 0 && braceDepth === 0) break;
          parenDepth = Math.max(0, parenDepth - 1);
        } else if (c === '}') braceDepth++;
        else if (c === '{') {
          if (braceDepth === 0 && parenDepth === 0) {
            p = -1;
            break;
          }
          braceDepth = Math.max(0, braceDepth - 1);
        }
        p--;
      }
      const callHeader = p >= 0 ? out.slice(Math.max(0, p - 40), p + 1) : '';
      if (SYNC_RENDER_CALL_PREFIX.test(callHeader)) {
        out += arrowMatch[0];
        i += arrowMatch[0].length;
        continue;
      }

      // Deferred UI callback closure: skip its arrow body.
      i += arrowMatch[0].length;
      while (i < body.length && /\s/.test(body[i])) i++;
      if (body[i] === '{') {
        let brace = 1;
        i++;
        for (; i < body.length && brace > 0; i++) {
          const c = body[i];
          if (c === "'" || c === '"' || c === '`') {
            const q = c;
            i++;
            while (i < body.length && body[i] !== q) {
              if (body[i] === '\\') i++;
              i++;
            }
            continue;
          }
          if (c === '{') brace++;
          else if (c === '}') brace--;
        }
      } else {
        let paren = 0;
        let brace = 0;
        for (; i < body.length; i++) {
          const c = body[i];
          if (c === "'" || c === '"' || c === '`') {
            const q = c;
            i++;
            while (i < body.length && body[i] !== q) {
              if (body[i] === '\\') i++;
              i++;
            }
            continue;
          }
          if (c === '(') paren++;
          else if (c === ')') {
            if (paren === 0 && brace === 0) break;
            paren--;
          } else if (c === '{') brace++;
          else if (c === '}') {
            if (brace === 0 && paren === 0) break;
            brace--;
          } else if ((c === ',' || c === '\n') && paren === 0 && brace === 0) {
            break;
          }
        }
      }
      out += 'noop';
      continue;
    }

    out += ch;
    i++;
  }
  return out;
}

function parseComponentMethods(source) {
  const methods = new Map();
  const builderNames = new Set();
  const lines = source.split('\n');
  let pendingBuilder = false;
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed === '@Builder') {
      pendingBuilder = true;
      continue;
    }
    const headerMatch = /^  (?:private |public )?(?:static )?(?:async )?([A-Za-z0-9_]+)\s*\(/.exec(lines[i]);
    if (headerMatch) {
      const name = headerMatch[1];
      if (name === 'if' || name === 'for' || name === 'while' || name === 'switch' || name === 'catch') {
        pendingBuilder = false;
        continue;
      }
      const startLine = i;
      let endLine = i;
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j] === '  }') {
          endLine = j;
          break;
        }
      }
      const body = lines.slice(startLine, endLine + 1).join('\n');
      methods.set(name, body);
      if (pendingBuilder || name === 'build') {
        builderNames.add(name);
      }
      pendingBuilder = false;
      i = endLine;
    } else if (trimmed.length > 0 && !trimmed.startsWith('//')) {
      pendingBuilder = false;
    }
  }
  return { methods, builderNames };
}

test('BridgeStatus.ets and TaildriveBrowser.ets have zero fileIo.*Sync calls reachable from build()/@Builder and zero JSON.stringify ForEach keys', () => {
  for (const relPath of [
    'entry/src/main/ets/components/BridgeStatus.ets',
    'entry/src/main/ets/components/TaildriveBrowser.ets'
  ]) {
    const source = readRepoFile(relPath);
    const { methods, builderNames } = parseComponentMethods(source);
    assert.ok(builderNames.has('build'), `${relPath} must contain build()`);
    assert.ok(builderNames.size > 5, `${relPath} must parse @Builder methods`);

    // 1. Check ForEach key generators across the entire component file for JSON.stringify
    const forEachBlocks = source.match(/ForEach\s*\([\s\S]*?\n\s*\}\s*,\s*\([^\n]*JSON\.stringify/g) ?? [];
    assert.deepEqual(
      forEachBlocks,
      [],
      `${relPath} must have zero ForEach key generators calling JSON.stringify`
    );

    // 2. Compute transitive synchronous call graph from build() and all @Builder methods
    const visited = new Set();
    const parentOf = new Map();
    const queue = [...builderNames];
    for (const root of queue) visited.add(root);

    while (queue.length > 0) {
      const current = queue.shift();
      const rawBody = methods.get(current);
      if (!rawBody) continue;
      const syncRenderBody = builderNames.has(current) ? stripDeferredEventClosures(rawBody) : rawBody;

      const syncIoMatch = /\bfileIo\.[A-Za-z0-9_]*Sync\s*\(/.exec(syncRenderBody);
      if (syncIoMatch) {
        const chain = [current];
        let p = parentOf.get(current);
        while (p) {
          chain.unshift(p);
          p = parentOf.get(p);
        }
        assert.fail(
          `${relPath} reaches synchronous ${syncIoMatch[0]}) during render via ${chain.join(' -> ')}`
        );
      }

      const callRegex = /\bthis\.([A-Za-z0-9_]+)\s*\(/g;
      let callMatch;
      while ((callMatch = callRegex.exec(syncRenderBody)) !== null) {
        const callee = callMatch[1];
        if (methods.has(callee) && !visited.has(callee)) {
          visited.add(callee);
          parentOf.set(callee, current);
          queue.push(callee);
        }
      }
    }
  }
});

test('TaildrivePreviewGateway times out hung AVMetadataExtractor operations without leaking fds or timers and invalidates stale .origin.json metadata', async () => {
  const mem = createMemoryFileIo();
  const dirs = new Set(['/data', '/data/files', '/data/cache']);
  let openCount = 0;
  let closeCount = 0;
  const activeTimers = new Map();
  let nextTimerId = 1;

  const baseOpenSync = mem.fileIo.openSync.bind(mem.fileIo);
  const baseCloseSync = mem.fileIo.closeSync.bind(mem.fileIo);
  const fdToPath = new Map();
  const fileIo = {
    ...mem.fileIo,
    accessSync(p) {
      const clean = String(p).replace(/\/+$/, '');
      return mem.files.has(clean) || dirs.has(clean);
    },
    async access(p) {
      return fileIo.accessSync(p);
    },
    async stat(p) {
      return fileIo.statSync(p);
    },
    async readText(p) {
      return mem.fileIo.readTextSync(String(p).replace(/\/+$/, ''));
    },
    mkdirSync(p) {
      const clean = String(p).replace(/\/+$/, '');
      const parts = clean.split('/').filter(Boolean);
      let cur = '';
      for (const part of parts) {
        cur += `/${part}`;
        dirs.add(cur);
      }
    },
    openSync(p, mode) {
      const clean = String(p).replace(/\/+$/, '');
      const isReadOnly = mode === mem.fileIo.OpenMode.READ_ONLY;
      const savedBytes = isReadOnly ? mem.rawBytes.get(clean) : undefined;
      const savedText = isReadOnly ? mem.files.get(clean) : undefined;
      const handle = baseOpenSync(clean, mode);
      if (isReadOnly && savedText !== undefined) {
        mem.rawBytes.set(clean, savedBytes);
        mem.files.set(clean, savedText);
      }
      fdToPath.set(handle.fd, clean);
      openCount++;
      return handle;
    },
    closeSync(fileOrFd) {
      const fd = typeof fileOrFd === 'number' ? fileOrFd : fileOrFd?.fd;
      fdToPath.delete(fd);
      closeCount++;
      return baseCloseSync(fileOrFd);
    },
    statSync(target) {
      if (typeof target === 'number' && fdToPath.has(target)) {
        return mem.fileIo.statSync(fdToPath.get(target));
      }
      if (typeof target === 'string') {
        const clean = target.replace(/\/+$/, '');
        if (dirs.has(clean) && !mem.files.has(clean)) {
          return { size: 0, mtime: 1000, isFile: () => false, isDirectory: () => true };
        }
      }
      return mem.fileIo.statSync(target);
    }
  };

  let extractorMode = 'hang_metadata';
  let releaseCalls = 0;
  const mediaMock = {
    AVImageQueryOptions: { AV_IMAGE_QUERY_CLOSEST_SYNC: 0 },
    async createAVMetadataExtractor() {
      return {
        fdSrc: undefined,
        fetchMetadata() {
          if (extractorMode === 'hang_metadata') {
            return new Promise(() => {});
          }
          return Promise.resolve({ videoWidth: '1920', videoHeight: '1080', duration: '4000' });
        },
        fetchFrameByTime() {
          if (extractorMode === 'hang_frame') {
            return new Promise(() => {});
          }
          return Promise.resolve({ release: async () => {} });
        },
        release() {
          releaseCalls++;
          if (extractorMode === 'hang_frame_and_release') {
            return new Promise(() => {});
          }
          return Promise.resolve();
        }
      };
    }
  };

  const ctx = loadEtsModules(
    ['services/AtomicFileStore', 'services/TaildrivePreviewGateway'],
    {
      fileIo,
      ControlServerConfig: { load: () => ({ controlURL: 'https://controlplane.tailscale.com' }) },
      AccountProfiles: {
        current: () => ({ activeId: 'default' }),
        cacheRoot: (_f, c) => c
      },
      image: {},
      media: mediaMock,
      setTimeout(cb, delay) {
        const id = nextTimerId++;
        activeTimers.set(id, { cb, delay });
        return id;
      },
      clearTimeout(id) {
        activeTimers.delete(id);
      },
      Date,
      Math,
      JSON,
      Number,
      Array,
      Promise
    }
  );

  const gateway = new ctx.TaildrivePreviewGateway();
  const appContext = { filesDir: '/data/files', cacheDir: '/data/cache' };
  const videoEntry = {
    path: '/tailnet/nas/movies/clip.mp4',
    name: 'clip.mp4',
    kind: 'file',
    size: 10,
    modifiedAtMs: 1700000000000,
    etag: '"etag-v1"'
  };

  const localVideoPath = gateway.prepareDownload(appContext, videoEntry);
  fileIo.mkdirSync(localVideoPath.slice(0, localVideoPath.lastIndexOf('/')));
  const f = fileIo.openSync(localVideoPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, '0123456789');
  fileIo.closeSync(f);

  const baselineOpens = openCount;
  const baselineCloses = closeCount;

  const flushMicrotasks = async (ticks = 24) => {
    for (let i = 0; i < ticks; i++) {
      await Promise.resolve();
    }
  };

  // 1. Hung fetchMetadata() times out at 5000ms, calls extractor.release(), closes sourceFile, and leaves zero timers.
  const pendingMeta = gateway.createThumbnail(appContext, videoEntry, localVideoPath);
  await flushMicrotasks();
  assert.equal(activeTimers.size, 1);
  const [metaTimerId, metaTimer] = [...activeTimers.entries()][0];
  assert.equal(metaTimer.delay, 5000);
  activeTimers.delete(metaTimerId);
  metaTimer.cb();
  assert.equal(await pendingMeta, '');
  assert.equal(releaseCalls, 1, 'extractor.release() called after fetchMetadata timeout');
  assert.equal(openCount - baselineOpens, 1);
  assert.equal(closeCount - baselineCloses, 1, 'sourceFile fd closed in finally');
  assert.equal(activeTimers.size, 0, 'zero leaked timers after settlement');

  // 2. Hung fetchFrameByTime() + hung extractor.release() BOTH time out (5000ms then 1500ms) and still close sourceFile!
  extractorMode = 'hang_frame';
  const pendingFrame = gateway.createThumbnail(appContext, videoEntry, localVideoPath);
  await flushMicrotasks();
  assert.equal(activeTimers.size, 1);
  extractorMode = 'hang_frame_and_release';
  const [frameTimerId, frameTimer] = [...activeTimers.entries()][0];
  assert.equal(frameTimer.delay, 5000);
  activeTimers.delete(frameTimerId);
  frameTimer.cb();

  await flushMicrotasks();
  assert.equal(activeTimers.size, 1, '1500ms release timeout armed');
  const [relTimerId, relTimer] = [...activeTimers.entries()][0];
  assert.equal(relTimer.delay, 1500);
  activeTimers.delete(relTimerId);
  relTimer.cb();

  assert.equal(await pendingFrame, '');
  assert.equal(releaseCalls, 2);
  assert.equal(openCount - baselineOpens, 2);
  assert.equal(closeCount - baselineCloses, 2, 'sourceFile fd closed even when release() hung');
  assert.equal(activeTimers.size, 0);

  // 3. .origin.json validates modifiedAtMs and etag across cachedPreview & cachedPreviewAsync, and prepareDownload removes stale .thumb.jpg
  const thumbFile = fileIo.openSync(`${localVideoPath}.thumb.jpg`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(thumbFile.fd, 'thumb-bytes');
  fileIo.closeSync(thumbFile);

  assert.ok(gateway.cachedPreview(appContext, videoEntry));
  assert.ok(await gateway.cachedPreviewAsync(appContext, videoEntry));
  assert.equal(gateway.cachedPreview(appContext, { ...videoEntry, modifiedAtMs: 1700000009999 }), undefined);
  assert.equal(await gateway.cachedPreviewAsync(appContext, { ...videoEntry, etag: '"etag-v2"' }), undefined);

  gateway.prepareDownload(appContext, { ...videoEntry, etag: '"etag-v2"' });
  assert.equal(fileIo.accessSync(`${localVideoPath}.thumb.jpg`), false, 'stale .thumb.jpg removed on next prepareDownload');
});

test('TaildriveBrowser.download() guards against concurrent re-entry during ensureFolderAccess and gateway.download, and cleans up uiTimers', async () => {
  const source = readRepoFile('entry/src/main/ets/components/TaildriveBrowser.ets');
  const extracted = [
    extractMethod(source, 'download'),
    extractMethod(source, 'scheduleUiTimer'),
    extractMethod(source, 'clearUiTimers')
  ].join('\n');

  const timers = new Map();
  let nextTimer = 1;
  let gatewayDownloadCalls = 0;
  let resolveAuth;
  let resolveDownload;

  const sandbox = {
    fileIo: { mkdirSync() {} },
    picker: {
      DocumentViewPicker: class {
        async save() { return ['file://dest/report.pdf']; }
      },
      DocumentSaveOptions: class {}
    },
    publishTaildriveCompletion: async () => {},
    setTimeout(cb, delay) {
      const id = nextTimer++;
      timers.set(id, { cb, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    }
  };
  vm.runInNewContext(
    stripTypeScriptTypes(`class BrowserHarness {\n${extracted}\n}\nglobalThis.BrowserHarness = BrowserHarness;`),
    sandbox
  );

  const h = new sandbox.BrowserHarness();
  const cleanedDirs = [];
  Object.assign(h, {
    connected: true,
    browserVisible: true,
    manualDownloadInFlight: false,
    manualDownloadCount: 0,
    uiTimers: [],
    status: '',
    ensureFolderAccess: () => new Promise(resolve => { resolveAuth = resolve; }),
    newTransferRequestId: () => 501,
    stagingRoot: () => '/cache/staging',
    clearRetry() {},
    setRetry() {},
    context: () => ({}),
    safeLocalName: n => n,
    markDownloadedEntry() {},
    showTransientStatus(s) { this.status = s; },
    cleanupDirectory(d) { cleanedDirs.push(d); },
    gateway: {
      download: () => {
        gatewayDownloadCalls++;
        return new Promise(resolve => { resolveDownload = resolve; });
      },
      exportFile: async () => true
    }
  });

  const fileEntry = { name: 'report.pdf', path: '/tailnet/nas/share/report.pdf', kind: 'file', size: 32, modifiedAtMs: 1 };

  // Start tap #1 -> pauses in ensureFolderAccess
  const firstTap = h.download(fileEntry);
  assert.equal(h.manualDownloadInFlight, true);

  // Tap #2 while ensureFolderAccess is awaiting -> rejected immediately!
  await h.download(fileEntry);
  assert.equal(gatewayDownloadCalls, 0);

  // Allow tap #1 into gateway.download -> tap #3 during active IPC transfer is ALSO rejected!
  resolveAuth(true);
  for (let i = 0; i < 8 && gatewayDownloadCalls === 0; i++) await Promise.resolve();
  assert.equal(gatewayDownloadCalls, 1);
  assert.equal(h.manualDownloadCount, 1);

  await h.download(fileEntry);
  assert.equal(gatewayDownloadCalls, 1, 'overlapping tap during gateway.download rejected');

  resolveDownload({ requestId: 501, state: 'completed', reason: '', bytes: 32 });
  await firstTap;
  assert.equal(h.manualDownloadInFlight, false);
  assert.equal(h.manualDownloadCount, 0);
  assert.deepEqual(cleanedDirs, ['/cache/staging/501']);
  assert.equal(h.status, 'download_completed');

  // Verify scheduleUiTimer self-removes on fire and clearUiTimers clears remaining timers on disappear
  const t1 = h.scheduleUiTimer(() => {}, 40);
  const t2 = h.scheduleUiTimer(() => {}, 40);
  assert.equal(h.uiTimers.length, 2);
  const fired = timers.get(t1);
  timers.delete(t1);
  fired.cb();
  assert.deepEqual(Array.from(h.uiTimers), [t2]);
  h.clearUiTimers();
  assert.deepEqual(Array.from(h.uiTimers), []);
  assert.equal(timers.size, 0);
});

test('TailscaleVpnExtensionAbility suppresses redundant snapshot writes within freshness windows and adapts taildropIncoming polling between 250ms and 1500ms', async () => {
  const vpnSource = readRepoFile('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets');
  const extracted = [
    extractMethod(vpnSource, 'writeTaildropSnapshot'),
    extractMethod(vpnSource, 'writePeerSnapshot'),
    extractMethod(vpnSource, 'clearTaildropIncomingTimer'),
    extractMethod(vpnSource, 'scheduleTaildropIncomingPoll'),
    extractMethod(vpnSource, 'refreshTaildropIncomingNotification')
  ].join('\n');

  let nowMs = 10_000;
  let incomingPayload = [];
  const atomicWrites = [];
  const scheduledTimeouts = new Map();
  let nextTimeoutId = 1;

  const sandbox = {
    TAILDROP_TARGETS_FILE_NAME: 'taildrop-targets.json',
    VPN_PEERS_FILE_NAME: 'vpn-peers.json',
    Date: { now: () => nowMs },
    Array,
    JSON,
    nativeBridge: {
      backendTaildropIncomingSnapshot: async () => JSON.stringify(incomingPayload)
    },
    setTimeout(cb, delay) {
      const id = nextTimeoutId++;
      scheduledTimeouts.set(id, { cb, delay });
      return id;
    },
    clearTimeout(id) {
      scheduledTimeouts.delete(id);
    }
  };

  vm.runInNewContext(
    stripTypeScriptTypes(`class VpnSnapshotHarness {\n${extracted}\n}\nglobalThis.VpnSnapshotHarness = VpnSnapshotHarness;`),
    sandbox
  );

  const vpn = new sandbox.VpnSnapshotHarness();
  let notificationUpdates = 0;
  Object.assign(vpn, {
    context: { filesDir: '/files' },
    destroying: false,
    backendStopInFlight: false,
    dnsRebuildInFlight: false,
    taildropIncomingSnapshotInFlight: false,
    taildropIncomingTimer: -1,
    taildropIncomingDelayMs: 0,
    taildropProgressNotificationVisible: false,
    lastTaildropSnapshotSignature: '',
    lastTaildropSnapshotWriteMs: 0,
    lastPeerSnapshotSignature: '',
    lastPeerSnapshotWriteMs: 0,
    latestTaildropSnapshot: { waitingFiles: [] },
    updateTaildropNotifications() { notificationUpdates++; },
    updateTaildropProgressNotification(incoming) {
      this.taildropProgressNotificationVisible = incoming.length > 0;
    },
    writeAtomicTextFile(path, content) {
      atomicWrites.push({ path, content, at: nowMs });
      return true;
    }
  });

  const baseSnapshot = {
    state: 'ready',
    reason: '',
    targets: [{ key: 'peer-0123456789abcdef', name: 'mac', os: 'macos', deviceModel: 'Mac', online: true }],
    incomingFiles: [],
    waitingFiles: [],
    inboxReason: '',
    transfer: {
      requestId: 0, state: 'idle', reason: '', targetKey: '', targetName: '',
      fileName: '', fileIndex: 0, fileCount: 0, fileBytes: 0, fileSize: 0,
      bytesSent: 0, totalBytes: 0, completedAtMs: 0
    }
  };
  const basePeers = [{ key: 'peer-0123456789abcdef', name: 'mac', online: true, addresses: ['100.64.0.2'] }];
  const baseReceiver = { state: 'ready', sent: 1, registered: 1 };

  // 1. Initial writes persist both snapshots
  vpn.writeTaildropSnapshot(baseSnapshot);
  vpn.writePeerSnapshot(basePeers, baseReceiver, undefined);
  assert.equal(atomicWrites.length, 2);
  assert.equal(notificationUpdates, 1);

  // 2. Identical snapshots 1s and 2s later are suppressed (< 2500ms peer window, < 4000ms taildrop window),
  //    while updateTaildropNotifications still runs!
  nowMs = 11_000;
  vpn.writeTaildropSnapshot(baseSnapshot);
  vpn.writePeerSnapshot(basePeers, baseReceiver, undefined);
  assert.equal(atomicWrites.length, 2, 'unchanged snapshots at +1000ms skipped');
  assert.equal(notificationUpdates, 2);

  // 3. At +2500ms, peer snapshot refreshes before BridgeStatus 5000ms expiry; taildrop (< 4000ms) still skipped
  nowMs = 12_500;
  vpn.writeTaildropSnapshot(baseSnapshot);
  vpn.writePeerSnapshot(basePeers, baseReceiver, undefined);
  assert.equal(atomicWrites.length, 3);
  assert.equal(atomicWrites[2].path, '/files/vpn-peers.json');

  // 4. At +4000ms, taildrop snapshot refreshes before BridgeStatus 10000ms expiry
  nowMs = 14_000;
  vpn.writeTaildropSnapshot(baseSnapshot);
  assert.equal(atomicWrites.length, 4);
  assert.equal(atomicWrites[3].path, '/files/taildrop-targets.json');

  // 5. Payload change within window writes immediately
  nowMs = 14_200;
  vpn.writePeerSnapshot([{ ...basePeers[0], online: false }], baseReceiver, undefined);
  assert.equal(atomicWrites.length, 5);

  // 6. Adaptive taildropIncoming polling: idle -> 1500ms, active incoming -> 250ms, idle again -> 1500ms
  incomingPayload = [];
  vpn.refreshTaildropIncomingNotification();
  for (let i = 0; i < 8; i++) await Promise.resolve();
  assert.equal(scheduledTimeouts.size, 1);
  let [tid, timerEntry] = [...scheduledTimeouts.entries()][0];
  assert.equal(timerEntry.delay, 1500, 'backs off to 1500ms when idle');

  // Incoming file arrives on next poll -> immediately schedules 250ms!
  incomingPayload = [{ name: 'photo.jpg', declaredSize: 1024, received: 512, startedAtMs: nowMs }];
  scheduledTimeouts.delete(tid);
  timerEntry.cb();
  for (let i = 0; i < 8; i++) await Promise.resolve();
  assert.equal(scheduledTimeouts.size, 1);
  [tid, timerEntry] = [...scheduledTimeouts.entries()][0];
  assert.equal(timerEntry.delay, 250, 'snaps to 250ms while incomingFiles.length > 0');

  // Incoming finishes -> backs off to 1500ms again
  incomingPayload = [];
  scheduledTimeouts.delete(tid);
  timerEntry.cb();
  for (let i = 0; i < 8; i++) await Promise.resolve();
  [tid, timerEntry] = [...scheduledTimeouts.entries()][0];
  assert.equal(timerEntry.delay, 1500, 'returns to 1500ms once transfer finishes');

  // Also if writeTaildropSnapshot observes incomingFiles.length > 0 while waiting on 1500ms, it snaps immediately to 250ms!
  vpn.writeTaildropSnapshot({
    ...baseSnapshot,
    incomingFiles: [{ name: 'fast.bin', declaredSize: 100, received: 10, startedAtMs: nowMs }]
  });
  [tid, timerEntry] = [...scheduledTimeouts.entries()][0];
  assert.equal(timerEntry.delay, 250, 'writeTaildropSnapshot immediately snaps idle 1500ms timer down to 250ms');
});

test('BridgeStatus async readTaildropTextPreview, async clearTemporaryStorage, and JSON.parse structural guards reject malformed payloads cleanly', async () => {
  const vpnCtrlSource = readRepoFile('entry/src/main/ets/services/VpnSessionController.ets');
  const taildropCtrlSource = readRepoFile('entry/src/main/ets/services/TaildropSessionController.ets');
  const extracted = [
    extractMethod(taildropCtrlSource, 'readTaildropTextPreview'),
    extractMethod(taildropCtrlSource, 'checkFileAccessibleAsync'),
    extractMethod(taildropCtrlSource, 'removeCacheEntry'),
    extractMethod(taildropCtrlSource, 'removeCacheEntryAsync'),
    extractMethod(taildropCtrlSource, 'clearTaildropPreviewCacheEntriesAsync'),
    extractMethod(taildropCtrlSource, 'clearTemporaryStorageEntriesAsync'),
    extractMethod(vpnCtrlSource, 'refreshPeerSnapshot'),
    extractMethod(taildropCtrlSource, 'refreshTaildropSnapshot'),
    extractMethod(vpnCtrlSource, 'refreshExitNodes')
  ].join('\n');

  let syncReadCalls = 0;
  let asyncReadCalls = 0;
  const files = new Map([
    ['/cache/hello.txt', 'hello async taildrop'],
    ['/cache/sub/item.tmp', 'cached-bytes'],
    ['/files/peers.json', 'null'],
    ['/files/taildrop.json', '{"state":"ready","targets":[],"waitingFiles":[],"incomingFiles":[],"transfer":null,"updatedAtMs":1000}']
  ]);
  const dirs = new Set(['/cache', '/cache/sub', '/files/history-media']);

  const fileIoMock = {
    accessSync: p => files.has(p) || dirs.has(p),
    async access(p) { return files.has(p) || dirs.has(p); },
    readTextSync(p) {
      if (p.startsWith('/cache/')) syncReadCalls++;
      return files.get(p);
    },
    async readText(p) {
      asyncReadCalls++;
      return files.get(p);
    },
    async stat(p) {
      if (files.has(p)) {
        const size = Buffer.byteLength(files.get(p), 'utf8');
        return { size, isFile: () => true, isDirectory: () => false };
      }
      if (dirs.has(p)) {
        return { size: 0, isFile: () => false, isDirectory: () => true };
      }
      throw new Error('ENOENT');
    },
    async listFile(dir) {
      const prefix = `${dir}/`;
      const names = new Set();
      for (const k of [...files.keys(), ...dirs]) {
        if (k.startsWith(prefix)) {
          const rest = k.slice(prefix.length);
          if (rest.length > 0) names.add(rest.split('/')[0]);
        }
      }
      return [...names];
    },
    async unlink(p) { files.delete(p); },
    async rmdir(d) { dirs.delete(d); }
  };

  const sandbox = {
    TAILDROP_TEXT_CLIPBOARD_MAX_BYTES: 1048576,
    TAILDROP_SNAPSHOT_FRESH_MS: 10000,
    VPN_PEERS_FILE_NAME: 'peers.json',
    fileIo: fileIoMock,
    emptyMeshArcReceiverStatus: () => ({ state: 'idle', sent: 0, registered: 0 }),
    sanitizeVpnDiagnosticToken: (v, fb) => v || fb,
    sanitizeVpnDiagnosticCount: v => Number.isFinite(v) ? v : 0,
    Date: { now: () => 1500 },
    Number,
    Array,
    JSON,
    Promise
  };
  vm.runInNewContext(
    stripTypeScriptTypes(`class BridgeIoHarness {\n${extracted}\n}\nglobalThis.BridgeIoHarness = BridgeIoHarness;`),
    sandbox
  );

  const b = new sandbox.BridgeIoHarness();
  Object.assign(b, {
    isConnected: () => true,
    taildropSnapshotFilePath: () => '/files/taildrop.json',
    maybeExpireTaildropCache() {},
    taildropState: 'ready',
    taildropTargets: [{ key: 'peer-0123456789abcdef' }],
    exitNodes: [{ id: 'old', name: 'Old', selected: true }],
    exitNodeStatus: '',
    networkSettingsGateway: { readExitNodes: () => '{"not":"an-array"}' },
    taildropPreviewCachePaths: () => [],
    taildropHistoryMediaRoot: () => '/files/history-media',
    host: {
      isConnected: () => true,
      getFilesDir: () => '/files',
      getCacheDir: () => '/cache',
      setTaildropState: s => { b.taildropState = s; },
      setTaildropReason() {},
      setTaildropTargets: t => { b.taildropTargets = t; },
      setExitNodes: e => { b.exitNodes = e; },
      setExitNodeUnavailableStatus: () => { b.exitNodeStatus = 'app.string.exit_node_list_unavailable'; },
      setExitNodeNoneStatus() {},
      setExitNodeSelectedStatus() {},
      setExitNodeRawStatus: s => { b.exitNodeStatus = s; }
    }
  });

  // 1. Async readTaildropTextPreview uses fileIo.stat + fileIo.readText (zero sync readTextSync calls)
  const previewText = await b.readTaildropTextPreview({
    requestId: 1, action: 'stage', state: 'staged', reason: '',
    name: 'hello.txt', size: Buffer.byteLength('hello async taildrop', 'utf8'), path: '/cache/hello.txt'
  });
  assert.equal(previewText, 'hello async taildrop');
  assert.equal(asyncReadCalls, 1);
  assert.equal(syncReadCalls, 0);

  // 2. Async clearTemporaryStorageEntriesAsync removes nested cache files & directories asynchronously
  assert.equal(await b.clearTemporaryStorageEntriesAsync(), true);
  assert.equal(files.has('/cache/hello.txt'), false);
  assert.equal(files.has('/cache/sub/item.tmp'), false);
  assert.equal(dirs.has('/cache/sub'), false);

  // 3. Structural JSON.parse guards protect refreshPeerSnapshot, refreshTaildropSnapshot, and refreshExitNodes
  assert.doesNotThrow(() => b.refreshPeerSnapshot(false));
  files.set('/files/peers.json', '{"peers":"bad","updatedAtMs":1200}');
  assert.doesNotThrow(() => b.refreshPeerSnapshot(false));

  let inboxApplied = 0;
  b.applyTaildropInboxSnapshot = () => { inboxApplied++; };
  assert.doesNotThrow(() => b.refreshTaildropSnapshot(true));
  assert.equal(inboxApplied, 0, 'null transfer object rejected before applyTaildropInboxSnapshot');

  // Persisted/offline TaildropSnapshot omitting incomingFiles is accepted when required fields are valid
  files.set(
    '/files/taildrop.json',
    '{"state":"ready","reason":"","targets":[],"waitingFiles":[],"inboxReason":"","transfer":{"requestId":0,"state":"idle"},"updatedAtMs":1200}'
  );
  b.refreshTaildropSnapshot(true);
  assert.equal(inboxApplied, 1, 'valid TaildropSnapshot omitting incomingFiles is accepted');

  b.refreshExitNodes();
  assert.deepEqual(Array.from(b.exitNodes), []);
  assert.equal(b.exitNodeStatus, 'app.string.exit_node_list_unavailable');
});

test('taildropPreviewCacheAvailable disables after clearTemporaryStorage, revision counter rejects stale async scans, and clearAppCache runs asynchronously', async () => {
  const taildropCtrlSource = readRepoFile('entry/src/main/ets/services/TaildropSessionController.ets');
  const extracted = [
    extractMethod(taildropCtrlSource, 'taildropPreviewCachePaths'),
    extractMethod(taildropCtrlSource, 'taildropPreviewCacheAvailable'),
    extractMethod(taildropCtrlSource, 'checkFileAccessibleAsync'),
    extractMethod(taildropCtrlSource, 'refreshTaildropPreviewAvailabilityAsync'),
    extractMethod(taildropCtrlSource, 'removeCacheEntry'),
    extractMethod(taildropCtrlSource, 'removeCacheEntryAsync'),
    extractMethod(taildropCtrlSource, 'clearTaildropPreviewCacheEntriesAsync'),
    extractMethod(taildropCtrlSource, 'clearTemporaryStorageEntriesAsync'),
    extractMethod(taildropCtrlSource, 'clearTemporaryStorage'),
    extractMethod(taildropCtrlSource, 'clearAppCacheEntriesAsync'),
    extractMethod(taildropCtrlSource, 'clearAppCache'),
    extractMethod(taildropCtrlSource, 'readTaildropTextPreview'),
    extractMethod(taildropCtrlSource, 'showCachedTaildropTextPreview')
  ].join('\n');

  const files = new Map([
    ['/inbox/1-thumb.jpg', 'thumb-bytes'],
    ['/inbox/1-media.mp4', 'video-bytes'],
    ['/inbox/2-note.txt', 'secret-note'],
    ['/app-cache/entry.bin', 'app-cache-bytes']
  ]);
  const dirs = new Set(['/cache', '/files/history-media', '/inbox', '/app-cache']);
  const pendingAccessChecks = [];
  let interceptAccess = false;
  let asyncUnlinkCount = 0;

  const fileIoMock = {
    accessSync: p => files.has(p) || dirs.has(p),
    access(p) {
      if (interceptAccess) {
        return new Promise(resolve => {
          pendingAccessChecks.push({ path: p, resolve });
        });
      }
      return Promise.resolve(files.has(p) || dirs.has(p));
    },
    async stat(p) {
      if (files.has(p)) {
        return { size: Buffer.byteLength(files.get(p), 'utf8'), isFile: () => true, isDirectory: () => false };
      }
      if (dirs.has(p)) {
        return { size: 0, isFile: () => false, isDirectory: () => true };
      }
      throw new Error('ENOENT');
    },
    async readText(p) {
      return files.get(p);
    },
    async listFile(dir) {
      const prefix = `${dir}/`;
      const names = new Set();
      for (const k of [...files.keys(), ...dirs]) {
        if (k.startsWith(prefix)) {
          const rest = k.slice(prefix.length);
          if (rest.length > 0) names.add(rest.split('/')[0]);
        }
      }
      return [...names];
    },
    async unlink(p) {
      asyncUnlinkCount++;
      files.delete(p);
    },
    async rmdir(d) {
      dirs.delete(d);
    }
  };

  const sandbox = {
    TAILDROP_TEXT_CLIPBOARD_MAX_BYTES: 1048576,
    fileIo: fileIoMock,
    JSON,
    Array,
    Promise
  };
  vm.runInNewContext(
    stripTypeScriptTypes(`class CacheRevisionHarness {\n${extracted}\n}\nglobalThis.CacheRevisionHarness = CacheRevisionHarness;`),
    sandbox
  );

  const flush = async () => {
    await new Promise(resolve => setImmediate(resolve));
  };

  const b = new sandbox.CacheRevisionHarness();
  let finishedClears = 0;
  let locked = false;
  Object.assign(b, {
    lifecycleGeneration: 1,
    controlServerEpoch: 1,
    taildropPreviewAvailabilityRevision: 0,
    taildropPreviewCachePresent: true,
    missingTaildropPreviewPaths: [],
    taildropMediaPreviews: [
      { requestId: 1, name: 'clip.mp4', size: 11, path: '/inbox/1-media.mp4', thumbnailPath: '/inbox/1-thumb.jpg', mediaType: 2 }
    ],
    taildropCachedFiles: [
      { requestId: 2, name: 'note.txt', size: 11, path: '/inbox/2-note.txt' }
    ],
    taildropReceiveThumbnailPath: '',
    taildropAutoPrefetchFailedKeys: [],
    taildropAutoPrefetchKey: '',
    taildropHistory: [],
    taildropWaitingFiles: [],
    taildropState: 'offline',
    cacheClearRequestedFromSettings: false,
    cacheClearInProgress: false,
    taildropReceivedText: '',
    cacheClearBlocked: () => b.cacheClearInProgress,
    taildropHistoryMediaRoot: () => '/files/history-media',
    appCacheRoots: () => ['/app-cache'],
    persistTaildropHistory() {},
    finishSettingsCacheClear() { this.cacheClearInProgress = false; finishedClears++; },
    queueTaildropPendingDeletes() {},
    clearTaildropInboxViewState() { this.taildropMediaPreviews = []; this.taildropCachedFiles = []; }
  });
  b.host = {
    getLifecycleGeneration: () => b.lifecycleGeneration,
    getControlServerEpoch: () => b.controlServerEpoch,
    getCacheDir: () => '/cache',
    getFilesDir: () => '/files',
    isSecurityCoverActive: () => locked,
    isTaildropPreviewCachePresent: () => b.taildropPreviewCachePresent,
    setTaildropPreviewCachePresent: v => { b.taildropPreviewCachePresent = v; },
    getMissingTaildropPreviewPaths: () => b.missingTaildropPreviewPaths,
    setMissingTaildropPreviewPaths: p => { b.missingTaildropPreviewPaths = p; },
    getTaildropMediaPreviews: () => b.taildropMediaPreviews,
    setTaildropMediaPreviews: p => { b.taildropMediaPreviews = p; },
    getTaildropCachedFiles: () => b.taildropCachedFiles,
    setTaildropCachedFiles: f => { b.taildropCachedFiles = f; },
    getTaildropHistory: () => b.taildropHistory,
    setTaildropHistory: h => { b.taildropHistory = h; },
    getTaildropWaitingFiles: () => b.taildropWaitingFiles,
    getTaildropState: () => b.taildropState,
    setCacheClearInProgress: v => { b.cacheClearInProgress = v; },
    setTaildropReceiveInProgress() {},
    setTaildropReceive() {},
    setTaildropReceivedText: t => { b.taildropReceivedText = t; },
    scheduleLifecycleTask(cb) { cb(); return 1; },
    refreshCacheSize() {},
    showTaildropToast() {}
  };

  // 1. Start a slow availability scan BEFORE clearing temporary storage
  assert.equal(b.taildropPreviewCacheAvailable(), true);
  interceptAccess = true;
  b.refreshTaildropPreviewAvailabilityAsync();
  await flush(4);
  assert.equal(pendingAccessChecks.length, 1);

  // 2. Run clearTemporaryStorage while the slow scan is in flight:
  //    taildropMediaPreviews (with thumbnailPath cleared to '') and taildropCachedFiles remain non-empty,
  //    yet taildropPreviewCacheAvailable() MUST become false!
  interceptAccess = false;
  b.clearTemporaryStorage();
  await flush();
  assert.equal(b.taildropMediaPreviews.length, 1);
  assert.equal(b.taildropMediaPreviews[0].thumbnailPath, '');
  assert.equal(b.taildropCachedFiles.length, 1);
  assert.equal(b.taildropPreviewCacheAvailable(), false, 'clear-cache button disables even when staged media/cached files remain');
  assert.equal(files.has('/inbox/1-thumb.jpg'), false);

  // 3. Resolve the stale pre-clear scan returning `true`: revision guard MUST discard it!
  while (pendingAccessChecks.length > 0) {
    pendingAccessChecks.shift().resolve(true);
    await flush(4);
  }
  await flush();
  assert.equal(b.taildropPreviewCacheAvailable(), false, 'stale availability scan cannot re-enable taildropPreviewCachePresent');

  // 4. showCachedTaildropTextPreview aborts post-await if App Lock activates or serverEpoch changes
  locked = true;
  assert.equal(await b.showCachedTaildropTextPreview(b.taildropCachedFiles[0]), false);
  assert.equal(b.taildropReceivedText, '');
  locked = false;

  // 5. clearAppCache runs asynchronously via clearAppCacheEntriesAsync and removes /app-cache/entry.bin
  const unlinksBeforeAppClear = asyncUnlinkCount;
  b.clearAppCache();
  await flush();
  assert.equal(files.has('/app-cache/entry.bin'), false);
  assert.ok(asyncUnlinkCount > unlinksBeforeAppClear, 'clearAppCache used async fileIo.unlink');
  assert.equal(finishedClears, 2);
});
