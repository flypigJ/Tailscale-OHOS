import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/TaildropSendGateway.ets', import.meta.url), 'utf8');

function fixture() {
  const paths = new Set(), handles = new Set();
  let copies = 0;
  const control = {
    active: true,
    size: 4,
    sourcePath: '/data/storage/el2/share/r/com.huawei.hmos.photos/Photo/1.jpg',
    isSymlink: false,
    afterCopy: () => {}
  };
  const stat = () => ({
    isFile: () => !control.isSymlink,
    isSymbolicLink: () => control.isSymlink,
    size: control.size
  });
  const fs = {
    OpenMode: { READ_ONLY: 1 },
    access: async p => paths.has(p),
    mkdir: async p => paths.add(p),
    open: async () => {
      handles.add(1);
      return { fd: 1, name: 'photo.jpg', path: control.sourcePath };
    },
    stat: async () => stat(),
    lstat: async () => ({ isFile: () => true, isSymbolicLink: () => false, size: control.size }),
    copyFile: async (_, p) => {
      copies++;
      paths.add(p);
      control.afterCopy();
    },
    close: async () => handles.delete(1),
    accessSync: p => paths.has(p),
    unlinkSync: p => paths.delete(p),
    rmdirSync: p => paths.delete(p),
    statSync: stat,
    listFileSync: p => [...paths].filter(x => x.startsWith(p + '/')).map(x => x.slice(p.length + 1))
  };
  const sandbox = { fileIo: fs };
  vm.runInNewContext(
    stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '')) +
      '\nthis.Gateway=TaildropSendGateway;',
    sandbox
  );
  return { gateway: new sandbox.Gateway(), control, paths, handles, copies: () => copies };
}

test('an unavailable thumbnail does not reject a valid copied file and closes its source', async () => {
  const f = fixture();
  const files = await f.gateway.prepareFiles(['file://media/1'], '/cache', 1, x => x, async () => {
    throw Error('codec');
  });
  assert.equal(files.length, 1);
  assert.equal(files[0].previewPath, '');
  assert.equal(f.handles.size, 0);
});

test('cancellation during a provider copy removes partial cache and closes its source', async () => {
  const f = fixture();
  f.control.afterCopy = () => { f.control.active = false; };
  await assert.rejects(f.gateway.prepareFiles(['file://media/1'], '/cache', 1, x => x, async () => '', () => f.control.active));
  assert.equal(f.paths.size, 0);
  assert.equal(f.handles.size, 0);
});

test('empty requests and unsafe source lengths never queue a copy', async () => {
  const f = fixture();
  await assert.rejects(f.gateway.prepareFiles([], '/cache', 1, x => x, async () => ''));
  f.control.size = Infinity;
  await assert.rejects(f.gateway.prepareFiles(['file://media/1'], '/cache', 1, x => x, async () => ''));
  assert.equal(f.copies(), 0);
  assert.equal(f.handles.size, 0);
  assert.equal(f.paths.size, 0);
});

test('kernel-resolved private sandbox source.path or symlink fd is rejected before copy and closes fd cleanly', async () => {
  const forbiddenResolvedPaths = [
    '/data/storage/el1/base/files/device-secret.json',
    '/data/storage/el2/base/files/tailscaled.state',
    '/data/storage/el3/base/files/key',
    '/data/storage/el4/base/files/key',
    '/data/app/el2/100/base/io.github.tailscaleohos/haps/entry/files/secret.txt'
  ];
  for (const badPath of forbiddenResolvedPaths) {
    const f = fixture();
    f.control.sourcePath = badPath;
    await assert.rejects(
      f.gateway.prepareFiles(['file://docs/1'], '/cache', 7, x => x, async () => ''),
      /Taildrop cache staging failed/
    );
    assert.equal(f.copies(), 0, `must not copy ${badPath}`);
    assert.equal(f.handles.size, 0, `must close fd for ${badPath}`);
    assert.equal(f.paths.size, 0, `must clean staging dir for ${badPath}`);
  }

  // Symlink fd is also rejected cleanly.
  const sym = fixture();
  sym.control.isSymlink = true;
  await assert.rejects(sym.gateway.prepareFiles(['file://docs/1'], '/cache', 8, x => x, async () => ''));
  assert.equal(sym.copies(), 0);
  assert.equal(sym.handles.size, 0);
  assert.equal(sym.paths.size, 0);
});
