// Validate the reviewed source pair before any normal native compilation.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const defaultRoot = path.resolve(__dirname, '..');
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase();
const read = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const git = (dir, ...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', windowsHide: true }).trim();
const lines = text => text ? text.split(/\r?\n/).sort() : [];
const same = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());
function checkedPath(base, relative) {
  if (path.isAbsolute(relative) || relative.split(/[\\/]/).includes('..')) throw new Error('Unsafe engine manifest path');
  return path.join(base, relative);
}
function verifyEngineInputs(root = defaultRoot, overrides = {}) {
  const lockPath = path.join(root, 'native/engine-lock.json');
  const lock = read(lockPath);
  if (lock.schemaVersion !== 1 || lock.engineVersion !== '1.104.5' || lock.goVersion !== 'go1.27.3') throw new Error('Unexpected engine version pair');
  for (const file of lock.inputs) {
    if (hash(checkedPath(root, file.path)) !== file.sha256) throw new Error(`Changed engine input: ${file.path}`);
  }
  const goRoot = path.resolve(overrides.goRoot || process.env.OHOS_GO_ROOT || checkedPath(root, lock.toolchainRoot));
  const vendorRoot = path.resolve(overrides.vendorRoot || checkedPath(root, lock.vendorRoot));
  const port = read(path.join(root, 'patches/experimental/k1-toolchain-manifest.json'));
  const vendor = read(checkedPath(root, lock.vendorManifest || 'patches/experimental/k4-cold-peer-manifest.json'));
  if (fs.readFileSync(path.join(goRoot, 'VERSION'), 'utf8').split(/\r?\n/)[0] !== lock.goVersion ||
      git(goRoot, 'rev-parse', 'HEAD^{tree}') !== lock.goBaselineTree ||
      git(vendorRoot, 'rev-parse', 'HEAD^{tree}') !== lock.vendorBaselineTree) throw new Error('Unreviewed source baseline');
  if (!same(lines(git(goRoot, 'diff', '--name-only', 'HEAD', '--', 'src')), port.changedFiles.map(f => f.path)) ||
      !same(lines(git(vendorRoot, 'diff', '--name-only', 'HEAD')), vendor.deltaFiles)) throw new Error('Unreviewed source delta');
  const generated = new Set(['src/cmd/cgo/zdefaultcc.go', 'src/cmd/dist/dist.exe', 'src/cmd/go/internal/cfg/zdefaultcc.go',
    'src/cmd/internal/objabi/zbootstrap.go', 'src/internal/buildcfg/zbootstrap.go', 'src/internal/runtime/sys/zversion.go', 'src/time/tzdata/zzipdata.go']);
  if (lines(git(goRoot, 'ls-files', '--others', '--exclude-standard', '--', 'src')).some(f => !generated.has(f)) ||
      git(vendorRoot, 'ls-files', '--others', '--exclude-standard')) throw new Error('Unrecorded source files');
  for (const [base, files] of [[goRoot, port.changedFiles], [vendorRoot, vendor.files]]) {
    for (const file of files) if (hash(checkedPath(base, file.path)) !== file.sha256) throw new Error(`Source bytes changed: ${file.path}`);
  }
  if (hash(path.join(goRoot, 'src/crypto/x509/verify.go')) !== port.securityVerifierSha256) throw new Error('Certificate verifier changed');
  if (process.platform === 'win32') {
    for (const file of lock.windowsToolBinaries) if (hash(checkedPath(goRoot, file.path)) !== file.sha256) throw new Error(`Unqualified compiler: ${file.path}`);
  }
  const go = path.join(goRoot, 'bin', process.platform === 'win32' ? 'go.exe' : 'go');
  const version = execFileSync(go, ['version'], { encoding: 'utf8', windowsHide: true,
    env: { ...process.env, GOROOT: goRoot, GOENV: 'off', GOTOOLCHAIN: 'local' } }).trim();
  if (!version.startsWith(`go version ${lock.goVersion} `)) throw new Error('Wrong compiler version');
  return { schemaVersion: 1, engineVersion: lock.engineVersion, goVersion: lock.goVersion, goRoot, vendorRoot,
    compilerSha256: hash(go), lockSha256: hash(lockPath), qualifiedWindowsCompiler: process.platform === 'win32' };
}
module.exports = { verifyEngineInputs, checkedPath };
if (require.main === module) {
  const overrides = {};
  const args = process.argv.slice(2);
  while (args.length) {
    const name = args.shift(), value = args.shift();
    if (!value || !['--go-root', '--vendor-root'].includes(name)) throw new Error('Unknown input verification argument');
    overrides[name === '--go-root' ? 'goRoot' : 'vendorRoot'] = value;
  }
  process.stdout.write(JSON.stringify(verifyEngineInputs(undefined, overrides)) + '\n');
}
