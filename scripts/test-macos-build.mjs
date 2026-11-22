import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const bash = process.env.BASH_PATH || (process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash');
const shellPath = value => value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);

function fixture(t) {
  // Include spaces to cover compiler and source path quoting.
  const root = mkdtempSync(path.join(tmpdir(), 'ohos build test '));
  t.after(() => {
    assert.equal(path.dirname(root), path.resolve(tmpdir()));
    rmSync(root, { recursive: true, force: true });
  });
  const put = (name, text) => {
    const target = path.join(root, name);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, text, { mode: 0o755 });
  };
  for (const name of ['build.sh', 'build-go.sh', 'verify-sdk-baseline.cjs']) {
    put(`scripts/${name}`, readFileSync(path.join(scripts, name), 'utf8'));
  }
  const git = (cwd, args) => {
    const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  };
  for (const [repo, patch] of [
    ['toolchain', 'ohos-go-interface-resources.patch'],
    ['third_party/tailscale', 'tailscale-ohos.patch']
  ]) {
    put(`${repo}/source.txt`, 'before\n');
    put(`${repo}/notes.txt`, 'original\n');
    const cwd = path.join(root, repo);
    git(cwd, ['init', '-q']);
    git(cwd, ['config', 'core.autocrlf', 'false']);
    git(cwd, ['add', 'source.txt', 'notes.txt']);
    put(`${repo}/source.txt`, 'after\n');
    put(`patches/${patch}`, git(cwd, ['diff', '--', 'source.txt']));
    put(`${repo}/source.txt`, 'before\n');
  }
  put('native/go_bridge/go.mod', 'module test\nrequire (\n tailscale.com v1.86.5\n)\n');
  // This suite exercises the shell driver. Input-verifier behavior has its
  // own tests; the fixture verifier lets us test refusal before compilation.
  put('scripts/verify-engine-inputs.cjs', `const fs=require('node:fs');const path=require('node:path');
const root=path.resolve(__dirname,'..');
if(fs.readFileSync(path.join(root,'third_party/tailscale/source.txt'),'utf8')!=='before\\n')throw new Error('Unreviewed source delta');
`);
  put('toolchain/bin/go', `#!/usr/bin/env bash
set -eu
printf '%s\\n' "$@" "CC=\${CC:-}" "CXX=\${CXX:-}" > "$GO_BUILD_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then
    shift
    printf library > "$1"
    printf header > "\${1%.so}.h"
    exit 0
  fi
  shift
done
exit 1
`);
  put('DevEco/sdk/default/openharmony/native/oh-uni-package.json', JSON.stringify({
    apiVersion: 26, releaseType: 'Release'
  }));
  const env = { ...process.env,
    DEVECO_STUDIO_HOME: shellPath(path.join(root, 'DevEco')),
    DEVECO_SDK_HOME: shellPath(path.join(root, 'DevEco/sdk')),
    OHOS_GO_ROOT: shellPath(path.join(root, 'toolchain')),
    GO_BUILD_LOG: shellPath(path.join(root, 'go-args.txt'))
  };
  const run = (name = 'build-go.sh', args = [], cwd = root) => spawnSync(bash,
    [shellPath(path.join(root, 'scripts', name)), ...args], { cwd, env, encoding: 'utf8' });
  return { root, put, run };
}

test('qualified inputs build repeatedly without rewriting sources and copy both outputs', t => {
  const f = fixture(t);
  for (let i = 0; i < 2; i++) {
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(path.join(f.root, 'third_party/tailscale/source.txt'), 'utf8'), 'before\n');
    assert.equal(readFileSync(path.join(f.root, 'entry/libs/arm64-v8a/libtailscale_go.h'), 'utf8'), 'header');
    const goArgs = readFileSync(path.join(f.root, 'go-args.txt'), 'utf8');
    assert.match(goArgs, /longStamp=1\.104\.5.*shortStamp=1\.104\.5/);
    assert.match(goArgs, /-extldflags=-Wl,-soname,libtailscale_go\.so,--build-id=sha1,-z,relro,-z,now,-z,noexecstack\b/);
    assert.match(goArgs, /CC=.*-fstack-protector-strong/);
    assert.match(goArgs, /CXX=.*-fstack-protector-strong/);
  }
});

test('the normal build does not mutate unrelated files', t => {
  const f = fixture(t);
  f.put('third_party/tailscale/notes.txt', 'local work\n');
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(path.join(f.root, 'third_party/tailscale/source.txt'), 'utf8'), 'before\n');
  assert.equal(readFileSync(path.join(f.root, 'third_party/tailscale/notes.txt'), 'utf8'), 'local work\n');
});

test('input verification failure stops before compiling and preserves the source', t => {
  const f = fixture(t);
  f.put('third_party/tailscale/source.txt', 'conflict\n');
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(path.join(f.root, 'go-args.txt')), false);
  assert.equal(readFileSync(path.join(f.root, 'third_party/tailscale/source.txt'), 'utf8'), 'conflict\n');
});

test('an older or non-Release native SDK is rejected before patching or compiling', testContext => {
  const fixtureContext = fixture(testContext);
  for (const metadata of [{ apiVersion: 23, releaseType: 'Release' }, { apiVersion: 26, releaseType: 'Beta' }]) {
    fixtureContext.put('DevEco/sdk/default/openharmony/native/oh-uni-package.json', JSON.stringify(metadata));
    const result = fixtureContext.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /requires the HarmonyOS API 26 Release SDK/);
    assert.equal(existsSync(path.join(fixtureContext.root, 'go-args.txt')), false);
    assert.equal(readFileSync(path.join(fixtureContext.root, 'third_party/tailscale/source.txt'), 'utf8'), 'before\n');
  }
});

test('Release and unknown products are rejected before any build or signing', t => {
  const f = fixture(t);
  for (const product of ['release', 'unknown']) {
    const result = f.run('build.sh', [product], tmpdir());
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /scripts\/build.ps1 -Product release/);
    assert.equal(existsSync(path.join(f.root, 'go-args.txt')), false);
  }
});

test('Debug uses the project directory, wrapper, and explicit debug flags', t => {
  const f = fixture(t);
  f.put('build-profile.json5', '{}\n');
  f.put('scripts/build-go.sh', '#!/usr/bin/env bash\nexit 0\n');
  f.put('DevEco/tools/hvigor/bin/hvigorw.js', '// mock\n');
  f.put('DevEco/tools/hvigor/hvigor/package.json', '{}\n');
  f.put('DevEco/tools/hvigor/hvigor-ohos-plugin/package.json', '{}\n');
  f.put('DevEco/tools/node/bin/node', `#!/usr/bin/env bash
printf '%s\\n' "$PWD" "$@" "NODE_PATH=\${NODE_PATH:-}" > "$GO_BUILD_LOG"
`);
  const result = f.run('build.sh', [], tmpdir());
  assert.equal(result.status, 0, result.stderr);
  const args = readFileSync(path.join(f.root, 'go-args.txt'), 'utf8');
  assert.match(args, /hvigorw\.js/);
  assert.match(args, /buildMode=debug/);
  assert.match(args, /debuggable=true/);
  assert.match(args, /NODE_PATH=\n$/);
  assert.ok(args.split('\n')[0].endsWith(path.basename(f.root)));
});
