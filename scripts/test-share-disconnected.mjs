import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const vpnCtrlSource=readFileSync(new URL('../entry/src/main/ets/services/VpnSessionController.ets',import.meta.url),'utf8');
const taildropCtrlSource=readFileSync(new URL('../entry/src/main/ets/services/TaildropSessionController.ets',import.meta.url),'utf8');
function method(src,name) {
  const text=src.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}','m'))?.[0];
  assert.ok(text,name);
  return text.replace(/^  (?:private )?async /,'async function ').replace(/^  (?:private )?/,'function ');
}
function fixture(present=true) {
  let resetCount=0, reads=0;
  const sandbox={fileIo:{accessSync:()=>present,readTextSync:()=>{reads++;return 'HarmonyOS VPN Extension destroyed';}},
    VPN_HEARTBEAT_FRESH_MS:5000,TAILDROP_SNAPSHOT_FRESH_MS:10000};
  loadEtsModules(['@tailscale/common'], sandbox);
  vm.runInContext(stripTypeScriptTypes(method(vpnCtrlSource,'refreshVpnProbeStatus')),sandbox);
  vm.runInContext(stripTypeScriptTypes(method(vpnCtrlSource,'refreshPeerSnapshot')),sandbox);
  vm.runInContext(stripTypeScriptTypes(method(taildropCtrlSource,'refreshTaildropSnapshot')),sandbox);
  const c={vpnStatus:'HarmonyOS VPN Extension Stopped',
    isConnected(){return this.vpnStatus.includes('state=Running');},preserveConfirmedVpnStatus:()=>false,
    processVpnBackendHandoffRequest(){}, resetTrafficMetrics(){},
    taildropTargets:[{key:'peer-test'}],taildropState:'ready',
    maybeExpireTaildropCache(){},taildropSnapshotFilePath:()=>'/files/targets'};
  c.host={
    getFilesDir:()=>'/files',
    isConnected:()=>c.isConnected(),
    getVpnStatus:()=>c.vpnStatus,
    setVpnStatus:v=>{c.vpnStatus=v;},
    resetTaildropSnapshot:()=>{resetCount++;c.taildropTargets=[];c.taildropState='disconnected';},
    resetStreamingStatesForDisconnect(){},
    syncHomeTitleCompact(){},
    isConnectInProgress:()=>false,
    isControlServerConfirmed:()=>true
  };
  c.connectedHomeLayoutActive=()=>false;
  return {c,sandbox,resets:()=>resetCount,reads:()=>reads};
}
test('repeated offline health probes never clear the UI backend target list',()=>{
  const f=fixture();
  for(let i=0;i<10;i++) {
    assert.equal(f.sandbox.refreshVpnProbeStatus.call(f.c),false);
    assert.equal(f.c.taildropTargets.length,1);
    assert.equal(f.c.taildropState,'ready');
  }
  assert.equal(f.resets(),0);
});
test('a real disconnect clears extension state once, even when its status file is absent',()=>{
  for(const present of [true,false]) {
    const f=fixture(present);f.c.vpnStatus='state=Running | tun=true';
    f.sandbox.refreshVpnProbeStatus.call(f.c);
    assert.equal(f.resets(),1);
    f.c.taildropTargets=[{key:'backend-target'}];f.c.taildropState='ready';
    f.sandbox.refreshVpnProbeStatus.call(f.c);
    assert.equal(f.resets(),1);assert.equal(f.c.taildropTargets.length,1);
  }
});
test('offline service refresh cannot read stale extension snapshots or replace backend state with loading',()=>{
  const f=fixture();
  f.sandbox.refreshTaildropSnapshot.call(f.c,false);
  // A service refresh started while connected may complete after disconnect.
  f.sandbox.refreshTaildropSnapshot.call(f.c,true);
  f.sandbox.refreshPeerSnapshot.call(f.c);
  assert.equal(f.reads(),0);assert.equal(f.c.taildropState,'ready');assert.equal(f.c.taildropTargets.length,1);
});
