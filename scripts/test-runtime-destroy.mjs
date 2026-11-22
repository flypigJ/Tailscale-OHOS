import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';
const source = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
function method(name) {
  const start = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source).index;
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const javascript = stripTypeScriptTypes('class Extension {\n' + ['onDestroy', 'finishDestroyedBackend', 'writeCurrentStatusHeartbeat'].map(method).join('\n') + '\n}\nglobalThis.Extension=Extension;');
function fixture() {
  const events=[]; let resolveDestroy;
  const gate = new Promise(resolve => { resolveDestroy=resolve; });
  const box={Date:{now:()=>1000},clearInterval(){},hilog:{info(){}},DOMAIN:0,TAG:''};
  loadEtsModules('@tailscale/common/contracts/VpnIpcContracts', box);
  vm.runInContext(javascript,box);
  const e=new box.Extension();
  Object.assign(e,{context:{filesDir:'/files'},explicitStopRequested:false,peerSnapshotRequestId:0,
    runtimeDiagnostic:{stop(){events.push('sampling_stopped');}},dnsObserver:{stop(){}},networkMonitor:{stop(){}},
    writeDnsSystemStatus(){},stopBackendStopWatcher(){},statusTimer:-1,taildropRequestTimer:-1,taildropIncomingTimer:-1,
    vpnConnection:{destroy:()=>gate},tunFd:1,latestTaildropSnapshot:{transfer:{state:'idle'}},
    writeTaildropSnapshot(){},writeStatus(){},recordDiagnosticEvent(name){events.push(name);},
    stopNativeBackend:async()=> 'OK',currentVisibleStatus:'state=Running | tun=true',backendSnapshotMs:500,
    writeAtomicTextFile(_path,text){e.status=text;}});
  return {e,events,resolveDestroy};
}
test('actual destroy records lifecycle before stopping sampling and preserves async tail callbacks', async()=>{
  const f=fixture(); f.e.onDestroy();
  assert.ok(f.events.indexOf('vpn_destroy_started')<f.events.indexOf('sampling_stopped'));
  assert.ok(f.events.indexOf('vpn_extension_destroyed')<f.events.indexOf('sampling_stopped'));
  assert.ok(f.events.includes('vpn_tun_destroy_started'));
  assert.ok(!f.events.includes('vpn_cleanup_completed'));
  f.resolveDestroy(); await new Promise(setImmediate);
  assert.ok(f.events.includes('vpn_tun_destroyed'));
  assert.ok(f.events.includes('vpn_backend_stopped'));
  assert.equal(f.events.at(-1),'vpn_cleanup_completed');
});
test('actual destroy captures TUN and backend errors without suppressing completion',async()=>{
  const f=fixture(); f.e.vpnConnection.destroy=async()=>{throw {code:201};};
  f.e.stopNativeBackend=async()=>{throw {code:202};};f.e.onDestroy();await new Promise(setImmediate);
  assert.ok(f.events.includes('vpn_tun_destroy_failed'));
  assert.ok(f.events.includes('vpn_backend_stop_failed'));
  assert.equal(f.events.at(-1),'vpn_cleanup_completed');
});
test('liveness heartbeat does not refresh backend snapshot age',()=>{
  const f=fixture();f.e.writeCurrentStatusHeartbeat();
  assert.match(f.e.status,/heartbeatMs=1000/);assert.match(f.e.status,/snapshotMs=500/);
});
