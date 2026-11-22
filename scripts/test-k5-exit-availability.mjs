import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import test from 'node:test';

const cliRoot = process.argv[2] && !process.argv[2].startsWith('-') ? process.argv[2] : undefined;
const root = cliRoot ?? fileURLToPath(new URL('..', import.meta.url));
const source = readFileSync(resolve(root, 'entry/src/main/ets/components/BridgeStatus.ets'), 'utf8').replace(/\r\n/g, '\n');
function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  const end = source.indexOf('\n  }', start);
  assert.ok(end >= 0);
  return source.slice(start, end + 4);
}
const context = vm.createContext({});
vm.runInContext(stripTypeScriptTypes(`class Controller {\n${method('canEditExitNode')}\n${method('onExitNodeSelect')}\n}\nglobalThis.Controller = Controller;`), context);
function ready() {
  const state = new context.Controller();
  Object.assign(state, {
    isAuthenticated: () => true, isConnected: () => false, isConnecting: () => false,
    exitNodes: [{ id: 'test-exit' }], connectInProgress: false, disconnectInProgress: false,
    exitNodeUpdateInProgress: false, backendRestartDeferred: false, backendReady: true,
    backendStatus: 'Tailscale Backend | state=Running',
    selectableExitNodes() { return this.exitNodes; },
    writes: [], queueExitNodeUpdate(id) { this.writes.push(id); }
  });
  return state;
}
test('fast reconnect keeps connection readiness without enabling a stopped settings backend', () => {
  const state = ready();
  state.backendRestartDeferred = true;
  assert.equal(state.canEditExitNode(), false);
  state.onExitNodeSelect(1);
  assert.deepEqual(state.writes, []);
  state.backendRestartDeferred = false;
  state.backendReady = false;
  assert.equal(state.canEditExitNode(), false);
  state.backendReady = true;
  state.backendStatus = 'STOPPED';
  assert.equal(state.canEditExitNode(), false);
  state.backendStatus = 'Tailscale Backend | state=Running';
  state.onExitNodeSelect(1);
  assert.deepEqual(state.writes, ['test-exit']);
  state.onExitNodeSelect(0);
  assert.deepEqual(state.writes, ['test-exit', '']);
});
test('stale selection callbacks do not write during a transition or without authentication', () => {
  const changes = [
    { isAuthenticated: () => false }, { exitNodes: [] }, { isConnected: () => true },
    { isConnecting: () => true }, { connectInProgress: true }, { disconnectInProgress: true },
    { exitNodeUpdateInProgress: true }
  ];
  for (const change of changes) {
    const state = Object.assign(ready(), change);
    state.onExitNodeSelect(0);
    state.onExitNodeSelect(1);
    assert.deepEqual(state.writes, []);
  }
});
test('compact and legacy controls use the same availability decision', () => {
  assert.match(source, /exitNodeEnabled: this\.canEditExitNode\(\)/);
  const legacy = source.slice(source.indexOf(".id('legacy-exit-node-status')"), source.indexOf(".id('legacy-exit-node-status')") + 1000);
  assert.match(legacy, /\.enabled\(this\.canEditExitNode\(\)\)/);
  assert.match(legacy, /\.opacity\(this\.canEditExitNode\(\) \? 1 : 0\.55\)/);
});
