import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/DnsSettings.ets', import.meta.url),
  'utf8');

function memoryFileIo() {
  const files = new Map();
  return {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: path => files.has(path),
    readTextSync: path => {
      if (!files.has(path)) {
        throw new Error('ENOENT');
      }
      return files.get(path);
    },
    openSync: path => {
      files.set(path, '');
      return { fd: path };
    },
    writeSync: (fd, text) => {
      files.set(fd, text);
      return text.length;
    },
    closeSync: () => {},
    renameSync: (from, to) => {
      if (!files.has(from)) {
        throw new Error('ENOENT');
      }
      files.set(to, files.get(from));
      files.delete(from);
    },
    unlinkSync: path => {
      files.delete(path);
    }
  };
}

function fixture() {
  let js = source.replace(/^import .*;\r?$/gm, '').replace(/export /g, '');
  js = stripTypeScriptTypes(js);
  const fileIo = memoryFileIo();
  const sandbox = { fileIo };
  vm.runInNewContext(js +
    '\nglobalThis.DnsSettingsStore = DnsSettingsStore;' +
    '\nglobalThis.MAX_DNS_SEARCH_DOMAINS = MAX_DNS_SEARCH_DOMAINS;', sandbox);
  return { store: sandbox.DnsSettingsStore, fileIo };
}

// Values created inside the vm realm have a different Array prototype, which
// deepStrictEqual treats as unequal even when the contents match.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test('accepts valid IPv4 and IPv6 resolver addresses', () => {
  const { store } = fixture();
  for (const address of ['223.5.5.5', '0.0.0.0', '255.255.255.255',
    '::1', '2001:db8::1', 'fe80::1', '::ffff:192.0.2.1', '2001:db8:0:0:0:0:2:1']) {
    assert.equal(store.isValidAddress(address), true, address);
  }
  for (const address of ['256.1.1.1', '1.2.3', '1.2.3.4.5', '01.2.3.4', 'a.b.c.d',
    '2001:db8::1::2', '2001:db8:::1', '12345::', 'gggg::1', '::1%eth0', '[::1]',
    '1:2:3:4:5:6:7:8:9']) {
    assert.equal(store.isValidAddress(address), false, address);
  }
});

test('normalizes search domains and rejects malformed labels', () => {
  const { store } = fixture();
  assert.deepEqual(plain(store.parseSearchDomains(' Corp.Example.COM , example.com., example.com, ')),
    ['corp.example.com', 'example.com']);
  for (const domain of ['corp.example.com', 'example.com.', '.example.com', 'local', 'a-b.example']) {
    assert.equal(store.isValidSearchDomain(domain), true, domain);
  }
  for (const domain of ['bad_domain.com', '-a.com', 'a-.com', 'a..b', '', 'a b.com', '中文.com']) {
    assert.equal(store.isValidSearchDomain(domain), false, domain);
  }
});

test('only enabled settings reach the VPN config and IPv6 is filtered when unavailable', () => {
  const { store } = fixture();
  const disabled = { enabled: false, primary: '1.1.1.1', secondary: '', searchDomains: ['x.com'] };
  assert.deepEqual(plain(store.vpnDnsAddresses(disabled, true)), []);
  assert.deepEqual(plain(store.vpnSearchDomains(disabled)), []);

  const enabled = { enabled: true, primary: '1.1.1.1', secondary: '2001:db8::1',
    searchDomains: ['x.com'] };
  assert.deepEqual(plain(store.vpnDnsAddresses(enabled, false)), ['1.1.1.1']);
  assert.deepEqual(plain(store.vpnDnsAddresses(enabled, true)), ['1.1.1.1', '2001:db8::1']);
  assert.deepEqual(plain(store.vpnSearchDomains(enabled)), ['x.com']);
});

test('rejects an enabled configuration without a valid primary resolver', () => {
  const { store } = fixture();
  assert.equal(store.normalize({ enabled: true, primary: '', secondary: '', searchDomains: [] }),
    undefined);
  assert.equal(store.normalize({ enabled: false, primary: 'bad', secondary: '', searchDomains: [] }),
    undefined);
  assert.equal(store.normalize({ enabled: false, primary: '1.1.1.1', secondary: 'bad',
    searchDomains: [] }), undefined);
});

test('round-trips through the atomic settings file', () => {
  const { store } = fixture();
  const saved = store.save('/files', {
    enabled: true,
    primary: '1.1.1.1',
    secondary: '8.8.8.8',
    searchDomains: ['corp.example.com']
  });
  assert.ok(saved);
  assert.deepEqual(plain(store.load('/files')), plain(saved));
  assert.deepEqual(plain(store.load('/other')), plain(store.defaults()));
});

test('invalid persisted JSON falls back to defaults', () => {
  const { store, fileIo } = fixture();
  fileIo.openSync('/files/dns-settings.json');
  fileIo.writeSync('/files/dns-settings.json', JSON.stringify({
    enabled: true, primary: 'not-an-ip', secondary: '', searchDomains: []
  }));
  assert.deepEqual(plain(store.load('/files')), plain(store.defaults()));
});
