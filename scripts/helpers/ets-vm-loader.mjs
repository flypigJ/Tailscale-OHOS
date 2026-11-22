import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix } from 'node:path';
import { isAnyArrayBuffer } from 'node:util/types';
import vm from 'node:vm';

const REPO_ROOT = new URL('../../', import.meta.url);
const LOADED_MODULES_BY_CONTEXT = new WeakMap();

function resolveRepoRelativePath(relPath) {
  const normalized = String(relPath).trim().replace(/\\/g, '/').replace(/^\/+/, '');
  if (normalized === '@tailscale/common') {
    return 'common/src/main/ets/Index.ets';
  }
  let candidate = normalized;
  if (normalized.startsWith('@tailscale/common/')) {
    candidate = `common/src/main/ets/${normalized.slice('@tailscale/common/'.length)}`;
  } else if (!normalized.startsWith('entry/') && !normalized.startsWith('common/')) {
    candidate = `entry/src/main/ets/${normalized}`;
  }
  if (!candidate.endsWith('.ets') && !candidate.endsWith('.ts')) {
    candidate += '.ets';
  }
  return candidate;
}

function resolveCommonDependencySpecifier(fromRepoPath, specifier) {
  const trimmed = String(specifier).trim();
  if (trimmed === '@tailscale/common' || trimmed.startsWith('@tailscale/common/')) {
    return resolveRepoRelativePath(trimmed);
  }
  if (fromRepoPath.startsWith('common/src/main/ets/') &&
    (trimmed.startsWith('./') || trimmed.startsWith('../'))) {
    let resolved = posix.normalize(posix.join(posix.dirname(fromRepoPath), trimmed));
    if (!resolved.endsWith('.ets') && !resolved.endsWith('.ts')) {
      resolved += '.ets';
    }
    if (resolved.startsWith('common/src/main/ets/')) {
      return resolved;
    }
  }
  return null;
}

function collectModuleSpecifiers(source) {
  const specs = [];
  const patterns = [
    /^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"]([^'"]+)['"]\s*;?[ \t]*\r?$/gm,
    /^export\s*(?:type\s*)?(?:\*(?:\s+as\s+[A-Za-z_$][A-Za-z0-9_$]*)?|\{[\s\S]*?\})\s*from\s*['"]([^'"]+)['"]\s*;?[ \t]*\r?$/gm
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(source)) !== null) {
      if (!specs.includes(match[1])) {
        specs.push(match[1]);
      }
    }
  }
  return specs;
}

export function readEtsSource(relPath) {
  const repoPath = resolveRepoRelativePath(relPath);
  return readFileSync(new URL(repoPath, REPO_ROOT), 'utf8');
}

function collectExportedRuntimeNames(source) {
  const names = [];
  const pattern = /^export\s+(?:default\s+)?(?:async\s+)?(?:class|function|const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\b/gm;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    if (!names.includes(match[1])) {
      names.push(match[1]);
    }
  }
  return names;
}

function collectExportedAliases(source) {
  const aliases = [];
  const pattern = /^export\s*\{([\s\S]*?)\}(?:\s*from\s*['"][^'"]+['"])?\s*;?[ \t]*\r?$/gm;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    for (const part of match[1].split(',')) {
      const item = part.trim();
      if (!item || item.startsWith('type ')) {
        continue;
      }
      const asMatch = /^([A-Za-z_$][A-Za-z0-9_$]*)\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)$/.exec(item);
      if (asMatch && asMatch[1] !== asMatch[2]) {
        aliases.push({ orig: asMatch[1], alias: asMatch[2] });
      }
    }
  }
  return aliases;
}

function collectCommonImportAliases(repoPath, source) {
  const aliases = [];
  const pattern = /^import\s*\{([\s\S]*?)\}\s*from\s*['"]([^'"]+)['"]\s*;?[ \t]*\r?$/gm;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    if (resolveCommonDependencySpecifier(repoPath, match[2]) === null) {
      continue;
    }
    for (const part of match[1].split(',')) {
      const item = part.trim();
      if (!item || item.startsWith('type ')) {
        continue;
      }
      const asMatch = /^([A-Za-z_$][A-Za-z0-9_$]*)\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)$/.exec(item);
      if (asMatch && asMatch[1] !== asMatch[2]) {
        aliases.push({ orig: asMatch[1], alias: asMatch[2] });
      }
    }
  }
  return aliases;
}

function expandModulesWithCommonDeps(relPaths, loadedSet) {
  const ordered = [];
  const visiting = new Set();

  const visit = (repoPath) => {
    if (loadedSet.has(repoPath) || visiting.has(repoPath)) {
      return;
    }
    visiting.add(repoPath);
    const raw = readFileSync(new URL(repoPath, REPO_ROOT), 'utf8');
    for (const spec of collectModuleSpecifiers(raw)) {
      const depRepoPath = resolveCommonDependencySpecifier(repoPath, spec);
      if (depRepoPath !== null) {
        visit(depRepoPath);
      }
    }
    visiting.delete(repoPath);
    loadedSet.add(repoPath);
    ordered.push({ repoPath, raw });
  };

  for (const relPath of relPaths) {
    visit(resolveRepoRelativePath(relPath));
  }
  return ordered;
}

export function stripEtsModuleSyntax(source) {
  const withoutImports = source
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '');
  const withoutExports = withoutImports
    .replace(/^export\s*(?:type\s*)?\{[\s\S]*?\}(?:\s*from\s*['"][^'"]+['"])?\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s*\*(?:\s+as\s+[A-Za-z_$][A-Za-z0-9_$]*)?\s+from\s*['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+default\s+/gm, '')
    .replace(/^export\s+/gm, '');
  return stripTypeScriptTypes(withoutExports);
}

export function loadEtsModules(relPaths, sandbox = {}, exportBindings = {}) {
  const list = Array.isArray(relPaths) ? relPaths : [relPaths];
  const context = vm.isContext(sandbox) ? sandbox : vm.createContext(sandbox);
  let loadedSet = LOADED_MODULES_BY_CONTEXT.get(context);
  if (!loadedSet) {
    loadedSet = new Set();
    LOADED_MODULES_BY_CONTEXT.set(context, loadedSet);
  }

  const expanded = expandModulesWithCommonDeps(list, loadedSet);
  const autoNames = [];
  const exportAliases = [];
  const chunks = expanded.map(({ repoPath, raw }) => {
    for (const name of collectExportedRuntimeNames(raw)) {
      if (!autoNames.includes(name)) {
        autoNames.push(name);
      }
    }
    for (const aliasEntry of collectExportedAliases(raw)) {
      exportAliases.push(aliasEntry);
    }
    const importAliasLines = collectCommonImportAliases(repoPath, raw)
      .map(({ orig, alias }) => `var ${alias} = typeof ${orig} !== 'undefined' ? ${orig} : undefined;`);
    const stripped = stripEtsModuleSyntax(raw);
    return importAliasLines.length > 0 ? `${importAliasLines.join('\n')}\n${stripped}` : stripped;
  });

  const bindingLines = [];
  for (const name of autoNames) {
    bindingLines.push(`if (typeof ${name} !== 'undefined') { globalThis.${name} = ${name}; }`);
  }
  for (const { orig, alias } of exportAliases) {
    bindingLines.push(`if (typeof ${orig} !== 'undefined') { globalThis.${alias} = ${orig}; }`);
  }
  if (Array.isArray(exportBindings)) {
    for (const symbolName of exportBindings) {
      bindingLines.push(`globalThis.${symbolName} = ${symbolName};`);
    }
  } else if (exportBindings && typeof exportBindings === 'object') {
    for (const [alias, symbolName] of Object.entries(exportBindings)) {
      bindingLines.push(`globalThis.${alias} = ${symbolName};`);
    }
  }

  vm.runInContext(`${chunks.join('\n')}\n${bindingLines.join('\n')}`, context);
  return context;
}

function toBuffer(data) {
  if (typeof data === 'string') {
    return Buffer.from(data, 'utf8');
  }
  if (isAnyArrayBuffer(data)) {
    return Buffer.from(data);
  }
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  }
  throw new TypeError('Unsupported writeSync payload');
}

export function createMemoryFileIo(options = {}) {
  const files = new Map();
  const rawBytes = new Map();
  const descriptors = new Map();
  const closeFailedFds = new Set();
  const events = [];
  let nextFd = 1;
  let failure = options.failure ?? '';
  let shortWriteChunkBytes = options.shortWriteChunkBytes ?? null;

  if (options.initialFiles) {
    const entries = options.initialFiles instanceof Map
      ? options.initialFiles.entries()
      : Object.entries(options.initialFiles);
    for (const [path, content] of entries) {
      const buf = toBuffer(content);
      rawBytes.set(path, buf);
      files.set(path, buf.toString('utf8'));
    }
  }

  const getBytes = (path) => {
    const text = files.get(path);
    const raw = rawBytes.get(path);
    if (raw && raw.toString('utf8') === text) {
      return raw;
    }
    const encoded = Buffer.from(text, 'utf8');
    rawBytes.set(path, encoded);
    return encoded;
  };

  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 2, READ_WRITE: 2, CREATE: 1, TRUNC: 4 },
    accessSync(path) {
      return files.has(path);
    },
    statSync(path) {
      if (!files.has(path)) {
        throw new Error(`ENOENT: ${path}`);
      }
      return {
        size: getBytes(path).length,
        mtime: Math.floor(Date.now() / 1000),
        isFile: () => true,
        isDirectory: () => false,
        isSymbolicLink: () => false
      };
    },
    readTextSync(path) {
      events.push(['read', path]);
      if (!files.has(path)) {
        throw new Error(`ENOENT: ${path}`);
      }
      return files.get(path);
    },
    mkdirSync(path) {
      events.push(['mkdir', path]);
    },
    listFileSync(dirPath) {
      const base = dirPath.endsWith('/') ? dirPath.slice(0, -1) : dirPath;
      const prefix = `${base}/`;
      const result = new Set();
      for (const key of files.keys()) {
        if (key.startsWith(prefix)) {
          const rest = key.slice(prefix.length);
          const slashIndex = rest.indexOf('/');
          result.add(slashIndex >= 0 ? rest.slice(0, slashIndex) : rest);
        }
      }
      return [...result];
    },
    openSync(path) {
      if (failure === 'open') {
        throw new Error('open_failed');
      }
      const fd = nextFd++;
      descriptors.set(fd, path);
      rawBytes.set(path, Buffer.alloc(0));
      files.set(path, '');
      events.push(['open', path, fd]);
      return { fd };
    },
    writeSync(fd, data) {
      if (!descriptors.has(fd)) {
        throw new Error('EBADF');
      }
      if (failure === 'write') {
        throw new Error('write_failed');
      }
      if (failure === 'zero_write') {
        events.push(['write', fd, 0]);
        return 0;
      }
      const incoming = toBuffer(data);
      let count = incoming.length;
      if (typeof shortWriteChunkBytes === 'number' && shortWriteChunkBytes > 0) {
        count = Math.min(incoming.length, shortWriteChunkBytes);
      } else if (failure === 'short_write') {
        count = Math.max(0, incoming.length - 1);
      }
      const path = descriptors.get(fd);
      const prev = rawBytes.get(path) ?? Buffer.alloc(0);
      const combined = Buffer.concat([prev, incoming.subarray(0, count)]);
      rawBytes.set(path, combined);
      files.set(path, combined.toString('utf8'));
      events.push(['write', fd, count]);
      return count;
    },
    fsyncSync(fd) {
      if (!descriptors.has(fd)) {
        throw new Error('EBADF');
      }
      if (failure === 'sync') {
        throw new Error('sync_failed');
      }
      events.push(['sync', fd]);
    },
    closeSync(file) {
      const fd = typeof file === 'number' ? file : file.fd;
      if (failure === 'close' && !closeFailedFds.has(fd)) {
        closeFailedFds.add(fd);
        throw new Error('close_failed');
      }
      if (!descriptors.delete(fd)) {
        throw new Error('EBADF');
      }
      events.push(['close', fd]);
    },
    renameSync(from, to) {
      if (failure === 'rename') {
        throw new Error('rename_failed');
      }
      if (descriptors.size > 0) {
        for (const openPath of descriptors.values()) {
          if (openPath === from) {
            throw new Error('EBUSY: rename before close');
          }
        }
      }
      if (!files.has(from)) {
        throw new Error(`ENOENT: ${from}`);
      }
      const bytes = getBytes(from);
      rawBytes.set(to, bytes);
      files.set(to, bytes.toString('utf8'));
      rawBytes.delete(from);
      files.delete(from);
      events.push(['rename', from, to]);
    },
    unlinkSync(path) {
      if (failure === 'unlink') {
        throw new Error('unlink_failed');
      }
      rawBytes.delete(path);
      files.delete(path);
      events.push(['unlink', path]);
    }
  };

  return {
    fileIo,
    files,
    rawBytes,
    descriptors,
    events,
    setFailure(nextFailure) {
      failure = nextFailure;
      closeFailedFds.clear();
    },
    setShortWriteChunkBytes(bytes) {
      shortWriteChunkBytes = bytes;
    },
    resetEvents() {
      events.length = 0;
    }
  };
}
