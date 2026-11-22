import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { readEtsSource, stripEtsModuleSyntax } from './helpers/ets-vm-loader.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const peerHelpersSource = readEtsSource('services/PeerIntegrationController');
const selectAddrFn = peerHelpersSource.match(/export function selectPrimaryTailscaleAddress[\s\S]*?^\}/m)?.[0];
const sunshineCandidateFn = peerHelpersSource.match(/export function isPeerSunshineCandidate[\s\S]*?^\}/m)?.[0];
const dnsSettingsSource = stripEtsModuleSyntax(readEtsSource('services/AtomicFileStore')) + '\n' +
  stripEtsModuleSyntax(readEtsSource('services/DnsSettings')) + '\n' +
  stripEtsModuleSyntax(`${selectAddrFn}\n${sunshineCandidateFn}`);
const peer = overrides => ({ key: 'p1', name: 'original-device', os: 'windows', deviceModel: '', deviceType: 'computer',
  addresses: ['fd7a::1', '100.64.0.1'], online: true, exitNode: false, keyExpired: false, keyExpiryUnixMs: 0, ...overrides });

function detailPropsSource() {
  const section = source.indexOf('  private DeviceDetailsContent(');
  const start = source.indexOf('DeviceDetailSheet({', section) + 'DeviceDetailSheet('.length;
  assert.ok(section > 0 && source[start] === '{');
  let depth = 0, quote = '';
  for (let at = start; at < source.length; at++) {
    const char = source[at];
    if (quote) { if (char === '\\') at++; else if (char === quote) quote = ''; continue; }
    if (char === '"' || char === "'" || char === '`') { quote = char; continue; }
    if (char === '{') depth++;
    if (char === '}' && --depth === 0) return source.slice(start, at + 1);
  }
  throw new Error('Device detail props object did not terminate');
}

function fixture() {
  const names = ['primaryTailscaleAddress', 'isSunshineCandidate', 'deviceDetailRenderKey'];
  for (const name of ['deviceDetailPeer', 'deviceDetailAddress', 'deviceDetailMagicDnsName', 'deviceDetailExitNodeCapable',
    'deviceDetailSunshineCandidate', 'withCurrentDeviceDetailPeer', 'copyDeviceDetailAddress']) {
    if (source.includes(`private ${name}(`)) names.push(name);
  }
  const methods = names.map(name => {
    const method = source.match(new RegExp(`^  private ${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(method, name);
    return method.replace(/^  private /, 'function ');
  });
  const sandbox = { $r: key => key };
  vm.runInNewContext(stripTypeScriptTypes(dnsSettingsSource + '\n' + methods.join('\n') +
    `\nfunction detailProps(peer: PeerSummary) { return (${detailPropsSource()}); }`), sandbox);
  const initial = peer();
  const state = {
    peers: [initial], selectedPeerKey: initial.key, appShellReady: true, deviceDetailVisible: true,
    tailnetDnsEnabled: true, appLockRequired: false, appLockAuthenticating: false,
    deviceDetailServiceRefreshInFlight: false, transferProtocolRefreshing: false, calls: [], copies: [],
    isConnected: () => true, canOpenContextGuide: () => true,
    streamingState: () => ({ path: { type: 'unknown' }, checking: false, sunshine: { state: 'unknown' }, launching: false }),
    mediaState: () => ({ checking: false, result: { services: [], state: 'unknown' }, launching: false }),
    mediaServiceNames: () => '', localSendStatusForPeer: () => undefined, localSendAvailableForPeer: () => false,
    taildropTargetAvailableForPeer: () => false, taildropTargetOnlineForPeer: () => false, taildropTargetReadyForPeer: () => false,
    launchRemoteStream(value) { this.calls.push(['stream', value]); },
    openMediaMethodForPeer(value) { this.calls.push(['media', value]); },
    openFileTransferFromDevice(value) { this.calls.push(['transfer', value]); },
    openRemoteFilesFromDevice(value) { this.calls.push(['files', value]); },
    copyDeviceValue(address) { this.copies.push(address); },
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  return { state, initial, props: sandbox.detailProps.call(state, initial), render: () => sandbox.detailProps.call(state, initial) };
}

test('saved device actions resolve the current peer instead of the initial ForEach object', () => {
  const { state, props } = fixture(); const current = peer({ name: 'current-device', addresses: ['100.64.0.2'], online: false });
  state.peers = [current];
  props.onOpenStream(); props.onOpenMedia(); props.onOpenFileTransfer(); props.onOpenRemoteFiles();
  assert.equal(state.calls.length, 4);
  assert.ok(state.calls.every(([, value]) => value === current));
});

test('detail fields update from the directory while the render key stays stable', () => {
  const { state, initial, render } = fixture();
  const current = peer({ name: 'current-device', addresses: ['fd7a::2', '100.64.0.2'], online: false, exitNode: true, os: 'android' });
  state.peers = [current]; const props = render();
  assert.equal(props.tailscaleAddress, '100.64.0.2'); assert.equal(props.exitNodeCapable, true);
  assert.equal(props.online, false); assert.equal(props.showSunshine, false);
  assert.equal(state.deviceDetailRenderKey(initial), state.deviceDetailRenderKey(current));
});

test('copy IP uses the current address and keeps offline address copying available', () => {
  const { state, props } = fixture(); state.peers = [peer({ addresses: ['fd7a::2', '100.64.0.2'], online: false })];
  props.onCopyIp(); assert.deepEqual(state.copies, ['100.64.0.2']);
});

test('empty or removed current addresses never replace the clipboard with stale data', () => {
  for (const peers of [[peer({ addresses: [] })], []]) {
    const { state, props } = fixture(); state.peers = peers; props.onCopyIp(); assert.equal(state.copies.length, 0);
  }
});

test('closed, switched or inactive details cannot invoke saved actions or copy', () => {
  for (const invalidate of [state => { state.deviceDetailVisible = false; },
    state => { state.selectedPeerKey = 'another'; }, state => { state.appShellReady = false; }, state => { state.peers = []; },
    state => { state.appLockRequired = true; }, state => { state.appLockAuthenticating = true; }]) {
    const { state, props } = fixture(); invalidate(state);
    props.onOpenStream(); props.onOpenMedia(); props.onOpenFileTransfer(); props.onOpenRemoteFiles(); props.onCopyIp();
    assert.equal(state.calls.length, 0); assert.equal(state.copies.length, 0);
  }
});

test('removed peers do not keep an address or capabilities in the detail projection', () => {
  const { state, render } = fixture(); state.peers = [];
  const props = render(); assert.equal(props.tailscaleAddress, '');
  assert.equal(props.exitNodeCapable, false); assert.equal(props.showSunshine, false);
});
