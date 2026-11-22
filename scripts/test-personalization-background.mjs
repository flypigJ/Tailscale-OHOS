import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/services/BackgroundImageStore.ets', import.meta.url), 'utf8')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');
const filesDir = '/data/storage/el2/base/haps/entry/files';
const directory = `${filesDir}/ui-backgrounds-v1`;
const pickerUri = 'file://media/Photo/IMG_1/photo.jpg';
const toUri = path => `file://io.github.tailscaleohos${path.split('/').map(encodeURIComponent).join('/')}`;

function fixture(options = {}) {
  const files = new Map([[pickerUri, { size: 12, content: 'original' }]]);
  const openFiles = new Map();
  const copies = [];
  const removed = [];
  const closed = [];
  const releases = [];
  const decodeSizes = [];
  let nextFd = 10;
  const fileIo = {
    OpenMode: { READ_ONLY: 0 },
    async open(uri, mode) {
      assert.equal(mode, 0);
      if (options.openError) throw new Error('open');
      if (!files.has(uri)) throw new Error('missing source');
      const file = { fd: nextFd++ };
      openFiles.set(file.fd, uri);
      return file;
    },
    async stat(path) {
      const entry = files.get(typeof path === 'number' ? openFiles.get(path) : path);
      if (options.statError && typeof path === 'number') throw new Error('stat');
      if (!entry) throw new Error('missing');
      return { size: options.sourceSize ?? entry.size,
        isFile: () => options.isDirectory && typeof path === 'number' ? false : true };
    },
    accessSync(path) { return files.has(path); },
    mkdirSync(path, recursive) {
      assert.equal(path, directory);
      assert.equal(recursive, true);
      if (options.mkdirError) throw new Error('mkdir');
      files.set(path, { directory: true });
    },
    async copyFile(fd, path) {
      assert.equal(typeof fd, 'number');
      assert.ok(openFiles.has(fd));
      assert.ok(!files.has(path), 'must never overwrite a prior copy');
      copies.push(path);
      files.set(path, { ...files.get(openFiles.get(fd)) });
      if (options.copyWait) await options.copyWait;
      if (options.copyError) throw new Error('copy');
      if (options.incomplete) files.get(path).size--;
    },
    closeSync(file) {
      closed.push(file.fd);
      openFiles.delete(file.fd);
      if (options.closeError) throw new Error('close');
    },
    unlinkSync(path) {
      removed.push(path);
      if (options.unlinkError) throw new Error('unlink');
      files.delete(path);
    }
  };
  const image = {
    createImageSource(fd) {
      assert.ok(openFiles.has(fd));
      if (options.createError) throw new Error('create');
      if (options.noImageSource) return undefined;
      return {
        async getImageInfo() {
          if (options.infoError) throw new Error('info');
          return { size: options.imageSize ?? { width: 4000, height: 3000 } };
        },
        async createPixelMap(settings) {
          decodeSizes.push(settings.desiredSize);
          if (options.decodeError) throw new Error('decode');
          return { async release() {
            releases.push('pixel');
            if (options.releaseError) throw new Error('release');
          } };
        },
        async release() {
          releases.push('source');
          if (options.releaseError) throw new Error('release');
        }
      };
    }
  };
  const fileUri = {
    getUriFromPath: path => {
      if (options.uriError) throw new Error('uri');
      return toUri(path);
    },
    FileUri: class {
      constructor(uri) {
        const parsed = new URL(uri);
        this.path = decodeURIComponent(parsed.pathname);
      }
    }
  };
  const sandbox = { fileIo, fileUri, image, Date: { now: () => 1730000000000 } };
  vm.runInNewContext(stripTypeScriptTypes(source) + '\nthis.Store = BackgroundImageStore;', sandbox);
  return { Store: sandbox.Store, files, openFiles, copies, removed, closed, releases, decodeSizes };
}

test('imports a validated private copy and keeps the picker original untouched', async () => {
  const f = fixture();
  const uri = await f.Store.importImage(filesDir, pickerUri);
  assert.equal(uri, toUri(f.copies[0]));
  assert.equal(f.files.get(pickerUri).content, 'original');
  assert.equal(f.files.get(f.copies[0]).content, 'original');
  assert.equal(f.Store.isManaged(filesDir, uri), true);
  assert.equal(f.openFiles.size, 0);
  assert.equal(f.closed.length, 1);
  assert.deepEqual(f.releases, ['pixel', 'source']);
  assert.deepEqual(JSON.parse(JSON.stringify(f.decodeSizes)), [{ width: 64, height: 48 }]);
  assert.deepEqual(f.removed, []);
});

for (const [name, options] of [
  ['source open', { openError: true }],
  ['source stat', { statError: true }],
  ['image creation', { createError: true }],
  ['image unavailable', { noImageSource: true }],
  ['image header', { infoError: true }],
  ['image payload', { decodeError: true }],
  ['directory creation', { mkdirError: true }],
  ['copy', { copyError: true }],
  ['short copy', { incomplete: true }],
  ['URI conversion', { uriError: true }]
]) {
  test(`${name} failure rejects without replacing or deleting an older background`, async () => {
    const f = fixture(options);
    const oldPath = `${directory}/background-old-1.img`;
    f.files.set(oldPath, { size: 10, content: 'old background' });
    await assert.rejects(f.Store.importImage(filesDir, pickerUri));
    assert.equal(f.files.get(oldPath).content, 'old background');
    assert.equal(f.files.get(pickerUri).content, 'original');
    assert.equal(f.openFiles.size, 0);
    assert.ok(f.removed.every(path => f.copies.includes(path)));
    assert.ok(f.copies.every(path => !f.files.has(path)));
    assert.equal(f.removed.includes(oldPath), false);
  });
}

for (const size of [0, -1, NaN, Infinity, 64 * 1024 * 1024 + 1]) {
  test(`rejects unsupported file size ${size} before decoding or copying`, async () => {
    const f = fixture({ sourceSize: size });
    await assert.rejects(f.Store.importImage(filesDir, pickerUri));
    assert.equal(f.openFiles.size, 0);
    assert.deepEqual(f.decodeSizes, []);
    assert.deepEqual(f.copies, []);
  });
}

test('rejects directories and invalid or unreasonable image dimensions', async () => {
  for (const options of [{ isDirectory: true },
    { imageSize: { width: 0, height: 1 } }, { imageSize: { width: 1, height: NaN } },
    { imageSize: { width: 1.5, height: 1 } }, { imageSize: { width: 20000, height: 20000 } }]) {
    const f = fixture(options);
    await assert.rejects(f.Store.importImage(filesDir, pickerUri));
    assert.equal(f.openFiles.size, 0);
    assert.deepEqual(f.copies, []);
  }
});

test('cleanup errors do not mask successful copy or prevent remaining resource cleanup', async () => {
  const f = fixture({ releaseError: true, closeError: true });
  const uri = await f.Store.importImage(filesDir, pickerUri);
  assert.equal(f.Store.isManaged(filesDir, uri), true);
  assert.deepEqual(f.releases, ['pixel', 'source']);
  assert.equal(f.closed.length, 1);
});

test('simultaneous imports get unique candidates even when the clock does not advance', async () => {
  let finishCopy;
  const f = fixture({ copyWait: new Promise(resolve => finishCopy = resolve) });
  const imports = Array.from({ length: 5 }, () => f.Store.importImage(filesDir, pickerUri));
  finishCopy();
  const uris = await Promise.all(imports);
  assert.equal(new Set(uris).size, 5);
  assert.equal(new Set(f.copies).size, 5);
  assert.equal(f.openFiles.size, 0);
});

test('does not overwrite a managed file left by a previous process at the same timestamp', async () => {
  const f = fixture();
  const oldPath = `${directory}/background-${(1730000000000).toString(36)}-1.img`;
  f.files.set(oldPath, { size: 10, content: 'old background' });
  await f.Store.importImage(filesDir, pickerUri);
  assert.notEqual(f.copies[0], oldPath);
  assert.equal(f.files.get(oldPath).content, 'old background');
});

test('managed deletion accepts only this store directory, canonical app URI and exact filename', () => {
  const f = fixture();
  const ownPath = `${directory}/background-old-1.img`;
  const ownUri = toUri(ownPath);
  const foreignUris = [pickerUri, ownPath, '', 'not a uri',
    toUri(`${filesDir}/other/background-old-1.img`),
    toUri(`${directory}-other/background-old-1.img`),
    toUri(`${directory}/background-user.jpg`),
    toUri(`${directory}/background-old-1.img/child`),
    toUri(`${directory}/../background-old-1.img`),
    ownUri.replace('io.github.tailscaleohos', 'other.app'),
    `${ownUri}?networkid=remote`, `${ownUri}#fragment`,
    toUri(`${directory}/background-old-1.img`).replace('background-', '%62ackground-')];
  for (const uri of foreignUris) {
    assert.equal(f.Store.isManaged(filesDir, uri), false, uri);
    f.Store.removeManaged(filesDir, uri);
  }
  assert.deepEqual(f.removed, []);
  assert.equal(f.Store.isManaged(filesDir, ownUri), true);
  f.Store.removeManaged(filesDir, ownUri);
  assert.deepEqual(f.removed, [ownPath]);
});

test('invalid roots cannot read or delete files and missing managed copies can be cleared', async () => {
  for (const root of ['', '/', 'relative/path', '/data/../private', '/data/./files', '/data\\files']) {
    const f = fixture();
    await assert.rejects(f.Store.importImage(root, pickerUri));
    f.Store.removeManaged(root, toUri(`${directory}/background-old-1.img`));
    assert.deepEqual(f.removed, []);
    assert.equal(f.closed.length, 0);
  }
  const f = fixture({ unlinkError: true });
  assert.doesNotThrow(() => f.Store.removeManaged(filesDir, toUri(`${directory}/background-old-1.img`)));
});
