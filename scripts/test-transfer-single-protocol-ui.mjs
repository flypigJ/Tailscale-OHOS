import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const taildropControllerSource = readFileSync(new URL('../entry/src/main/ets/services/TaildropSessionController.ets', import.meta.url), 'utf8');

function extractMethod(name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = source.match(new RegExp(`^  private ${escaped}\\([\\s\\S]*?^  \\}`, 'm'));
  assert.ok(match, `missing method ${name}`);
  return match[0];
}

function createController() {
  const names = [
    'displayedTaildropTargets',
    'taildropTargetForPeer',
    'taildropTargetOnlineForPeer',
    'taildropTargetReadyForPeer',
    'localSendAvailableForPeer',
    'peerEffectivelyOnline',
    'peerForFileTransferKey',
    'fileTransferCapabilitiesForPeer',
    'taildropProtocolState',
    'taildropTargetReady',
    'localSendProtocolState',
    'localSendAvailableForTarget',
    'transferTargetDeviceOffline',
    'taildropFileChoicesVisible',
    'transferTargetRenderKey',
    'localSendOnlyTargetRenderKey'
  ];
  const sandbox = {};
  const code = `class Controller {
    constructor() {
      this.connected = true;
      this.taildropState = 'ready';
      this.taildropTargets = [];
      this.peers = [];
      this.transferProtocolRefreshing = false;
      this.contentChoiceEnabled = true;
    }
    isConnected() { return this.connected; }
    taildropContentChoiceEnabled() { return this.contentChoiceEnabled; }
    ${names.map(extractMethod).join('\n')}
  }\nglobalThis.Controller = Controller;`;
  vm.runInNewContext(stripTypeScriptTypes(code), sandbox);
  return new sandbox.Controller();
}

test('Taildrop-only online peer stays consistent across badge, 3-segment capsule, and temporary send disable', () => {
  for (const localState of ['offline', 'unavailable', 'timeout', 'unknown', undefined]) {
    const c = createController();
    const target = { key: 'peer-a', name: 'pc', deviceType: 'computer', online: true };
    const peer = {
      key: 'peer-a',
      name: 'pc.tail.ts.net',
      deviceType: 'computer',
      online: true,
      localSend: localState === undefined ? undefined : { state: localState }
    };
    c.taildropTargets = [target];
    c.peers = [peer];

    assert.equal(c.taildropProtocolState(target), 'online');
    assert.equal(c.localSendProtocolState(peer), 'offline');
    assert.equal(c.taildropFileChoicesVisible(target, peer), true,
      `Taildrop-only should show 3-option capsule when localSend=${String(localState)}`);

    // Opening picker or starting transfer must disable segments in place without collapsing to single button
    const idleKey = c.transferTargetRenderKey(target);
    c.contentChoiceEnabled = false;
    assert.equal(c.taildropFileChoicesVisible(target, peer), true);
    assert.equal(c.transferTargetRenderKey(target), idleKey);
  }
});

test('non-ready Taildrop state never shows Taildrop online badge alongside collapsed single button', () => {
  const c = createController();
  const target = { key: 'peer-a', name: 'pc', deviceType: 'computer', online: true };
  const peer = { key: 'peer-a', name: 'pc', online: true, localSend: { state: 'offline' } };
  c.taildropTargets = [target];
  c.peers = [peer];

  c.taildropState = 'loading';
  assert.equal(c.taildropProtocolState(target), 'checking');
  assert.equal(c.taildropTargetReady(target), false);
  assert.equal(c.taildropFileChoicesVisible(target, peer), false);
  const loadingKey = c.transferTargetRenderKey(target);

  c.taildropState = 'ready';
  assert.equal(c.taildropProtocolState(target), 'online');
  assert.equal(c.taildropTargetReady(target), true);
  assert.equal(c.taildropFileChoicesVisible(target, peer), true);
  assert.notEqual(c.transferTargetRenderKey(target), loadingKey);

  c.taildropState = 'disabled';
  assert.equal(c.taildropProtocolState(target), 'offline');
  assert.equal(c.taildropFileChoicesVisible(target, peer), false);
});

test('LocalSend probe checking or dual-online uses single send-file capsule and updates render key', () => {
  const c = createController();
  const target = { key: 'peer-a', name: 'pc', deviceType: 'computer', online: true };
  c.taildropTargets = [target];
  c.peers = [{ key: 'peer-a', name: 'pc', online: true, localSend: { state: 'offline' } }];
  const taildropOnlyKey = c.transferTargetRenderKey(target);

  c.transferProtocolRefreshing = true;
  assert.equal(c.localSendProtocolState(c.peers[0]), 'checking');
  assert.equal(c.taildropFileChoicesVisible(target, c.peers[0]), false);
  const refreshingKey = c.transferTargetRenderKey(target);
  assert.notEqual(refreshingKey, taildropOnlyKey);

  c.transferProtocolRefreshing = false;
  c.peers = [{ key: 'peer-a', name: 'pc', online: true, localSend: { state: 'available' } }];
  assert.equal(c.localSendProtocolState(c.peers[0]), 'online');
  assert.equal(c.taildropFileChoicesVisible(target, c.peers[0]), false);
  assert.notEqual(c.transferTargetRenderKey(target), refreshingKey);
});

test('LocalSend-only row matches TaildropTargetRow card anatomy without discordant layout fallback', () => {
  const taildropRow = extractMethod('TaildropTargetRow');
  const localSendRow = extractMethod('LocalSendOnlyTargetRow');
  const mediaCapsule = extractMethod('TaildropFileMediaCapsule');

  assert.match(taildropControllerSource, /const TAILDROP_SNAPSHOT_FRESH_MS:\s*number\s*=\s*10000;/);
  assert.match(taildropRow, /this\.taildropTargetReady\(target\)\s*\|\|\s*this\.localSendAvailableForTarget\(target\)/);
  assert.match(taildropRow, /this\.peerDisplayName\(target\.name\)/);
  assert.match(taildropRow, /this\.RemotePortEditorPanel\(\)/);

  assert.doesNotMatch(mediaCapsule, /startFileTransferForPeer/);
  assert.match(mediaCapsule, /chooseTaildropDocuments\(target\)/);

  assert.doesNotMatch(localSendRow, /ic_light_connect|ROUNDED_RECTANGLE|device_detail_transfer_localsend_description/);
  assert.match(localSendRow, /this\.peerDeviceIcon\(peer\.deviceType\)/);
  assert.match(localSendRow, /this\.TransferProtocolBadge\('Taildrop', 'offline'\)/);
  assert.match(localSendRow, /this\.TransferProtocolBadge\('LocalSend'/);
  assert.match(localSendRow, /this\.PeerActionSegment\(\$r\('app\.string\.transfer_send_file_action'\)/);
  assert.match(localSendRow, /\.height\(36\)/);
  assert.match(localSendRow, /\.borderRadius\(18\)/);
  assert.match(localSendRow, /this\.RemotePortEditorPanel\(\)/);
  assert.match(localSendRow, /\?\s*1\s*:\s*0\.52/);

  const c = createController();
  const capturedPeer = { key: 'peer-b', name: 'mac', online: true, localSend: { state: 'offline' } };
  c.peers = [capturedPeer];
  const offKey = c.localSendOnlyTargetRenderKey(capturedPeer);
  c.peers = [{ key: 'peer-b', name: 'mac', online: true, localSend: { state: 'available' } }];
  assert.equal(c.localSendProtocolState(capturedPeer), 'online');
  assert.notEqual(c.localSendOnlyTargetRenderKey(capturedPeer), offKey);
});
