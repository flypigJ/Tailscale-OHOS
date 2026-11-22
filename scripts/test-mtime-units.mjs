import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const readSource = (relativePath) =>
  readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8');

const vpnSource = readSource('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets');
const taildropCtrlSource = readSource('entry/src/main/ets/services/TaildropSessionController.ets');

function extractMethod(source, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}(?:<[^>]+>)?\\([\\s\\S]*?^  \\}`, 'm').exec(source);
  assert.ok(match, `expected production method ${name}`);
  return match[0];
}

function extractConst(source, name) {
  const match = new RegExp(`^const ${name}\\b[^\\n]+`, 'm').exec(source);
  assert.ok(match, `expected production const ${name}`);
  return match[0];
}

function createFakeFs() {
  const entries = new Map();
  const utimesCalls = [];

  const ensureParent = (path) => {
    const slash = path.lastIndexOf('/');
    if (slash > 0) {
      const parent = path.slice(0, slash);
      if (!entries.has(parent)) {
        entries.set(parent, { kind: 'dir', mtime: 0, size: 0 });
      }
    }
  };

  const makeStat = (entry) => ({
    mtime: entry.mtime,
    size: entry.size ?? 0,
    isFile: () => entry.kind === 'file',
    isDirectory: () => entry.kind === 'dir',
    isSymbolicLink: () => false
  });

  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000 },
    accessSync(path) {
      return entries.has(path);
    },
    mkdirSync(path) {
      ensureParent(path);
      if (!entries.has(path)) {
        entries.set(path, { kind: 'dir', mtime: 0, size: 0 });
      }
    },
    listFileSync(dir) {
      if (!entries.has(dir)) {
        throw new Error(`ENOENT: ${dir}`);
      }
      const prefix = `${dir}/`;
      const names = [];
      for (const key of entries.keys()) {
        if (key.startsWith(prefix)) {
          const rest = key.slice(prefix.length);
          if (rest.length > 0 && !rest.includes('/')) {
            names.push(rest);
          }
        }
      }
      return names;
    },
    statSync(target) {
      const entry = entries.get(target);
      if (!entry) {
        throw new Error(`ENOENT: ${target}`);
      }
      return makeStat(entry);
    },
    lstatSync(target) {
      return fileIo.statSync(target);
    },
    readTextSync(path) {
      const entry = entries.get(path);
      if (!entry || entry.kind !== 'file') {
        throw new Error(`ENOENT: ${path}`);
      }
      return entry.content ?? '';
    },
    unlinkSync(path) {
      if (!entries.has(path)) {
        throw new Error(`ENOENT: ${path}`);
      }
      entries.delete(path);
    },
    rmdirSync(dir) {
      if (!entries.has(dir)) {
        throw new Error(`ENOENT: ${dir}`);
      }
      for (const key of entries.keys()) {
        if (key.startsWith(`${dir}/`)) {
          throw new Error(`ENOTEMPTY: ${dir}`);
        }
      }
      entries.delete(dir);
    },
    openSync(uri) {
      const entry = entries.get(uri);
      if (!entry) {
        throw new Error(`ENOENT: ${uri}`);
      }
      return { fd: uri, name: entry.name ?? uri.slice(uri.lastIndexOf('/') + 1) };
    },
    closeSync() {},
    async copyFile(sourceFd, destination) {
      const src = entries.get(sourceFd);
      if (!src) {
        throw new Error(`ENOENT: ${sourceFd}`);
      }
      if (src.copyGate) {
        await src.copyGate;
      }
      ensureParent(destination);
      entries.set(destination, {
        kind: 'file',
        mtime: src.copiedMtimeSec ?? src.mtime,
        size: src.size,
        content: src.content ?? ''
      });
    },
    utimes(path, mtimeMs) {
      const entry = entries.get(path);
      if (!entry) {
        throw new Error(`ENOENT: ${path}`);
      }
      utimesCalls.push({ path, mtimeMs });
      // HarmonyOS fileIo.utimes accepts milliseconds while Stat.mtime reports seconds.
      entry.mtime = Math.floor(mtimeMs / 1000);
    }
  };

  return { entries, utimesCalls, fileIo };
}

test('TailscaleVpnExtensionAbility.cleanupStaleTaildropInbox compares Stat.mtime seconds against millisecond retention cutoff', () => {
  const nowMs = 1_795_000_000_000;
  const fs = createFakeFs();
  const root = '/files/taildrop-inbox-export';
  fs.entries.set(root, { kind: 'dir', mtime: Math.floor(nowMs / 1000), size: 0 });

  const recentPath = `${root}/recent.jpg`;
  const expiredPath = `${root}/expired.jpg`;
  const unretainedPath = `${root}/orphan.jpg`;
  const zeroMtimePath = `${root}/zero.jpg`;
  const futurePath = `${root}/future.jpg`;
  const nanMtimePath = `${root}/nan.jpg`;

  fs.entries.set(recentPath, { kind: 'file', mtime: Math.floor(nowMs / 1000) - 60, size: 128 });
  fs.entries.set(expiredPath, { kind: 'file', mtime: Math.floor((nowMs - 8 * 86_400_000) / 1000), size: 128 });
  fs.entries.set(unretainedPath, { kind: 'file', mtime: Math.floor(nowMs / 1000) - 10, size: 128 });
  fs.entries.set(zeroMtimePath, { kind: 'file', mtime: 0, size: 128 });
  fs.entries.set(futurePath, { kind: 'file', mtime: Math.floor(nowMs / 1000) + 3600, size: 128 });
  fs.entries.set(nanMtimePath, { kind: 'file', mtime: Number.NaN, size: 128 });

  fs.entries.set('/files/taildrop-inbox-snapshot.json', {
    kind: 'file',
    mtime: Math.floor(nowMs / 1000),
    size: 256,
    content: JSON.stringify({
      cachedFiles: [
        { path: recentPath },
        { path: expiredPath },
        { path: zeroMtimePath },
        { path: futurePath },
        { path: nanMtimePath }
      ]
    })
  });

  const sandbox = {
    Date: { now: () => nowMs },
    Number,
    JSON,
    fileIo: fs.fileIo,
    AccountProfiles: { cacheRoot: () => '/files' }
  };
  loadEtsModules('@tailscale/common', sandbox);
  const snippet = [
    extractConst(vpnSource, 'TAILDROP_CACHE_RETENTION_MS'),
    'class VpnInboxHarness {',
    extractMethod(vpnSource, 'cleanupStaleTaildropInbox'),
    extractMethod(vpnSource, 'retainedTaildropInboxPaths'),
    extractMethod(vpnSource, 'retainTaildropInboxPath'),
    '}',
    'globalThis.VpnInboxHarness = VpnInboxHarness;'
  ].join('\n');
  vm.runInContext(stripTypeScriptTypes(snippet), sandbox);

  const ext = new sandbox.VpnInboxHarness();
  ext.context = { filesDir: '/files' };
  ext.serverControlURL = 'https://controlplane.tailscale.com';
  ext.serverProfileId = 'default';
  ext.taildropInboxRoot = () => root;

  ext.cleanupStaleTaildropInbox();

  assert.equal(fs.entries.has(recentPath), true, 'recent retained file in seconds must be kept');
  assert.equal(fs.entries.has(expiredPath), false, 'retained file older than 7d in seconds must be deleted');
  assert.equal(fs.entries.has(unretainedPath), false, 'unretained file must be deleted');
  assert.equal(fs.entries.has(zeroMtimePath), true, 'retained file with mtime=0 must be kept');
  assert.equal(fs.entries.has(futurePath), true, 'retained file with future mtime must be kept');
  assert.equal(fs.entries.has(nanMtimePath), true, 'retained file with non-finite mtime must be kept');
});

test('TaildriveGateway.stageUpload converts Stat.mtime seconds to milliseconds and cleanupStaleStaging protects activeStagedDirs', async () => {
  const nowMs = 1_795_200_000_000;
  const fs = createFakeFs();
  const root = '/cache/taildrive-staging';
  fs.entries.set(root, { kind: 'dir', mtime: Math.floor(nowMs / 1000), size: 0 });

  const sandbox = {
    Date: { now: () => nowMs },
    Number,
    Set,
    Promise,
    Error,
    JSON,
    setTimeout,
    clearTimeout,
    fileIo: fs.fileIo,
    AccountProfiles: { token: () => 'default:0' },
    ControlServerConfig: { load: () => ({ controlURL: 'https://test.invalid', updatedAtMs: 1 }) }
  };
  loadEtsModules('services/TaildriveGateway', sandbox);

  const gateway = new sandbox.TaildriveGateway();

  fs.entries.set('file://picked/report.pdf', {
    kind: 'file',
    name: 'report.pdf',
    mtime: 1_795_000_000,
    size: 2048
  });

  const prepared = await gateway.stageUpload('file://picked/report.pdf', root, 101);
  assert.equal(prepared.modifiedAtMs, 1_795_000_000_000);
  assert.deepEqual(fs.utimesCalls, [
    { path: `${root}/101/upload.taildrive`, mtimeMs: 1_795_000_000_000 }
  ]);

  // Simulate an old mtime on the still-active staged request directory (101),
  // plus fresh (<24h), stale (>24h), and in-flight copy directories.
  fs.entries.get(`${root}/101`).mtime = Math.floor((nowMs - 72 * 3_600_000) / 1000);

  const freshDir = `${root}/202`;
  fs.entries.set(freshDir, { kind: 'dir', mtime: Math.floor((nowMs - 2 * 3_600_000) / 1000), size: 0 });
  fs.entries.set(`${freshDir}/upload.taildrive`, { kind: 'file', mtime: Math.floor(nowMs / 1000), size: 64 });

  const staleDir = `${root}/303`;
  fs.entries.set(staleDir, { kind: 'dir', mtime: Math.floor((nowMs - 25 * 3_600_000) / 1000), size: 0 });
  fs.entries.set(`${staleDir}/upload.taildrive`, { kind: 'file', mtime: Math.floor((nowMs - 25 * 3_600_000) / 1000), size: 64 });

  let releaseCopy;
  const copyGate = new Promise((resolve) => { releaseCopy = resolve; });
  fs.entries.set('file://picked/inflight.bin', {
    kind: 'file',
    name: 'inflight.bin',
    mtime: 0,
    size: 512,
    copyGate
  });
  const inflightPromise = gateway.stageUpload('file://picked/inflight.bin', root, 404);
  fs.entries.get(`${root}/404`).mtime = Math.floor((nowMs - 48 * 3_600_000) / 1000);

  gateway.cleanupStaleStaging(root);

  assert.equal(fs.entries.has(freshDir), true, 'fresh (<24h) staging directory in seconds must be kept');
  assert.equal(fs.entries.has(staleDir), false, 'stale (>24h) staging directory in seconds must be removed');
  assert.equal(fs.entries.has(`${root}/101`), true, 'active staged directory must never be deleted before cleanupStaged');
  assert.equal(fs.entries.has(`${root}/404`), true, 'in-flight staged directory must never be deleted during copyFile');

  releaseCopy();
  const inflightPrepared = await inflightPromise;
  assert.equal(inflightPrepared.modifiedAtMs, 0);
  assert.equal(fs.utimesCalls.length, 1, 'mtime=0 must not invoke utimes');

  gateway.cleanupStaged(prepared);
  assert.equal(fs.entries.has(`${root}/101`), false, 'cleanupStaged removes completed request directory');

  // Once released via cleanupStaged, activeStagedDirs no longer blocks stale cleanup if recreated old.
  fs.entries.set(`${root}/101`, { kind: 'dir', mtime: Math.floor((nowMs - 30 * 3_600_000) / 1000), size: 0 });
  gateway.cleanupStaleStaging(root);
  assert.equal(fs.entries.has(`${root}/101`), false);
});

test('BridgeStatus.cleanupExpiredTaildropPreviewCache and restoreTaildropVideoMtime scale Stat.mtime seconds to milliseconds', async () => {
  const nowMs = 1_795_000_000_000;
  const fs = createFakeFs();
  let metadataPayload = { dateTimeFormat: '2026-05-01 12:30:45', duration: '5000' };
  let releasedCount = 0;

  const sandbox = {
    Date: Object.assign(function (...args) { return new Date(...args); }, {
      now: () => nowMs,
      parse: (v) => Date.parse(v)
    }),
    Number,
    setTimeout,
    clearTimeout,
    fileIo: fs.fileIo,
    media: {
      async createAVMetadataExtractor() {
        return {
          fdSrc: undefined,
          async fetchMetadata() { return metadataPayload; },
          async release() { releasedCount++; }
        };
      }
    }
  };

  const snippet = [
    extractConst(taildropCtrlSource, 'TAILDROP_CACHE_RETENTION_MS'),
    extractConst(taildropCtrlSource, 'TAILDROP_MEDIA_MIN_TIMESTAMP_MS'),
    extractConst(taildropCtrlSource, 'TAILDROP_MEDIA_MAX_FUTURE_MS'),
    extractConst(taildropCtrlSource, 'TAILDROP_MEDIA_MAX_DURATION_MS'),
    'class BridgeMtimeHarness {',
    extractMethod(taildropCtrlSource, 'taildropPreviewCachePaths'),
    extractMethod(taildropCtrlSource, 'cleanupExpiredTaildropPreviewCache'),
    extractMethod(taildropCtrlSource, 'validTaildropMediaTimestamp'),
    extractMethod(taildropCtrlSource, 'taildropLocalDateTimestamp'),
    extractMethod(taildropCtrlSource, 'parseTaildropMediaDateTime'),
    extractMethod(taildropCtrlSource, 'taildropMediaTimestampFromName'),
    extractMethod(taildropCtrlSource, 'withMediaTimeout'),
    extractMethod(taildropCtrlSource, 'restoreTaildropVideoMtime'),
    '}',
    'globalThis.BridgeMtimeHarness = BridgeMtimeHarness;'
  ].join('\n');
  vm.runInNewContext(stripTypeScriptTypes(snippet), sandbox);

  const bridge = new sandbox.BridgeMtimeHarness();
  const recentThumb = '/files/taildrop-inbox-export/recent-thumb.jpg';
  const expiredThumb = '/files/taildrop-inbox-export/expired-thumb.jpg';
  const zeroThumb = '/files/taildrop-inbox-export/zero-thumb.jpg';

  fs.entries.set(recentThumb, { kind: 'file', mtime: Math.floor(nowMs / 1000) - 300, size: 512 });
  fs.entries.set(expiredThumb, { kind: 'file', mtime: Math.floor((nowMs - 8 * 86_400_000) / 1000), size: 512 });
  fs.entries.set(zeroThumb, { kind: 'file', mtime: 0, size: 512 });

  bridge.host = {
    isTaildropReceiveInProgress: () => false,
    getTaildropMediaPreviews: () => [
      { thumbnailPath: recentThumb },
      { thumbnailPath: expiredThumb }
    ]
  };
  bridge.taildropReceiveThumbnailPath = zeroThumb;

  const cutoffMs = nowMs - 7 * 24 * 60 * 60 * 1000;
  const changed = bridge.cleanupExpiredTaildropPreviewCache(cutoffMs);
  assert.equal(changed, true);
  assert.equal(fs.entries.has(recentThumb), true, 'recent preview thumbnail in seconds must be kept');
  assert.equal(fs.entries.has(expiredThumb), false, 'expired (>7d) preview thumbnail in seconds must be unlinked');
  assert.equal(fs.entries.has(zeroThumb), true, 'preview thumbnail with mtime=0 must be kept');

  const videoPath = '/files/taildrop-inbox-export/VID_20260501_123045.mp4';
  fs.entries.set(videoPath, { kind: 'file', mtime: 0, size: 4096 });
  const restoredMs = await bridge.restoreTaildropVideoMtime('VID_20260501_123045.mp4', videoPath, 4096);
  const expectedLocalMs = new Date(2026, 4, 1, 12, 30, 45, 0).getTime();

  assert.equal(fs.utimesCalls.length, 1);
  assert.equal(fs.utimesCalls[0].mtimeMs, expectedLocalMs);
  assert.equal(fs.entries.get(videoPath).mtime, Math.floor(expectedLocalMs / 1000));
  assert.equal(restoredMs, Math.floor(expectedLocalMs / 1000) * 1000, 'restored mtime must be returned in milliseconds');
  assert.equal(releasedCount, 1);

  fs.fileIo.utimes = () => { fs.entries.get(videoPath).mtime = 0; };
  assert.equal(await bridge.restoreTaildropVideoMtime('VID_20260501_123045.mp4', videoPath, 4096), undefined);
});
