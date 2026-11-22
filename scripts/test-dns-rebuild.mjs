import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
const read = path => readFileSync(new URL('../entry/src/main/ets/' + path + '.ets', import.meta.url), 'utf8');
const source = read('vpnextensionability/TailscaleVpnExtensionAbility');
const method = (text,name) => text.match(new RegExp('^  private (?:async )?'+name+'\\([\\s\\S]*?^  }','m'))[0];
const deferred = () => { let resolve; const promise = new Promise(r => { resolve=r; }); return {promise,resolve}; };
const flush = async () => { for(let i=0;i<50;i++)await Promise.resolve(); };
const plan = (session='a', suffix='old.test') => ({schemaVersion:1,session:session.repeat(32),revision:1,state:'ready',dnsAddresses:['100.100.100.100'],searchDomains:[suffix]});
function fixture() {
  const f={now:10000,wanted:true,trace:[],gates:new Map(),statuses:[],timers:0};
  f.pause=async name=>{f.trace.push(name);if(f.gates.has(name))await f.gates.get(name).promise;};
  const box={Date:{now:()=>f.now},setTimeout:(cb,ms)=>{f.now+=ms;queueMicrotask(()=>{f.onTimer?.();cb();});return ++f.timers;},
    PathDiagnosticService:{shutdown:async()=>f.pause('path')},
    vpnExtension:{createVpnConnection:()=>{f.trace.push('create-connection');return {destroy:async()=>f.pause('new-destroy')};}},
    PhysicalDnsService:{read:async()=>f.physical??{networkId:1,resolvers:['192.0.2.53']}},
    DnsRuntimeService:{update:async()=>f.trace.push('update-base'),read:async()=>f.actual??plan(),sameConfiguration:(a,b)=>JSON.stringify([a.dnsAddresses,a.searchDomains])===JSON.stringify([b.dnsAddresses,b.searchDomains])}};
  const policy=read('services/DnsRebuildPolicy').replace(/^export /gm,'');
  const names=['refreshPhysicalDnsBase','dnsActiveTransferInFlight','dnsRequestsDrained','rebuildDnsVpn','writeStatus'];
  vm.runInNewContext(stripTypeScriptTypes(policy+'\nclass Owner {\n'+names.map(n=>method(source,n)).join('\n')+'\n}\nglobalThis.Owner=Owner;globalThis.Policy=DnsRebuildPolicy;'),box);
  f.owner=new box.Owner();
  const c=f.owner;
  f.old={destroy:async()=>f.pause('destroy')};
  Object.assign(c,{context:{filesDir:'/files'},vpnConnection:f.old,tunFd:7,dnsSystemPlan:plan(),
    dnsBaseFingerprint:JSON.stringify({networkId:1,resolvers:['192.0.2.53']}),nextDnsBaseRefreshMs:0,
    destroying:false,explicitStopRequested:false,backendStopInFlight:false,dnsRebuildInFlight:false,dnsBaseRefreshInFlight:false,
    dnsRebuildPolicy:new box.Policy(),dnsObserver:{stop:()=>f.trace.push('observer-stop')},networkMonitor:{stop:()=>f.trace.push('monitor-stop')},
    startupIntentAllowed:()=>f.wanted,writeCurrentStatusHeartbeat:()=>f.statuses.push(c.currentVisibleStatus),writeDnsSystemStatus:(state,applied)=>f.statuses.push({state,applied}),
    recordDiagnosticEvent:(event,phase,code)=>f.trace.push([event,phase,code]),
    stopNativeBackend:async()=>{await f.pause('stop');return 'OK';},processBackendStopRequest:()=>false,
    finishDestroyedBackend:async()=>f.pause('cleanup'),
    nativeStopPromise:Promise.resolve('old-stop'),backendRestartPromise:Promise.resolve('old-restart'),
    createProbeTun:async()=>{assert.equal(c.nativeStopPromise,undefined);assert.equal(c.backendRestartPromise,undefined);await f.pause('start');c.tunFd=9;c.dnsSystemPlan=plan('b','new.test');c.currentVisibleStatus='OK | state=Running | tun=true';}});
  return f;
}
test('DNS rebuild policy coalesces work, limits repeated failures and enforces a cooldown across policy changes',()=>{
  const f=fixture(),p=f.owner.dnsRebuildPolicy;
  assert.equal(p.begin('a',10000),true);assert.equal(p.begin('b',10000),false);p.finish(false);
  assert.equal(p.begin('b',20000),false);assert.equal(p.begin('a',40000),true);p.finish(false);
  assert.equal(p.begin('a',70000),false);assert.equal(p.begin('b',70000),true);p.finish(true);
});
test('same physical DNS still observes a changed compiled search-domain plan',async()=>{
  const f=fixture();f.actual=plan('a','new.test');let rebuilt=0;
  f.owner.rebuildDnsVpn=async p=>{assert.equal(p.searchDomains[0],'new.test');rebuilt++;};
  await f.owner.refreshPhysicalDnsBase();assert.equal(rebuilt,1);assert.equal(f.trace.includes('update-base'),false);
});
test('unchanged system plans refresh physical upstreams without recreating a TUN',async()=>{
  const f=fixture();f.physical={networkId:2,resolvers:['192.0.2.54']};
  f.owner.rebuildDnsVpn=async()=>assert.fail('unchanged plan must not rebuild');
  await f.owner.refreshPhysicalDnsBase();assert.ok(f.trace.includes('update-base'));assert.equal(f.owner.dnsBaseFingerprint,JSON.stringify(f.physical));
});
test('rebuild destroys old TUN before native stop and resets stop/restart promises before new startup',async()=>{
  const f=fixture();await f.owner.rebuildDnsVpn(plan('a','new.test'));
  assert.ok(f.trace.indexOf('destroy')<f.trace.indexOf('stop'));assert.ok(f.trace.indexOf('stop')<f.trace.indexOf('start'));
  assert.equal(f.owner.vpnConnection,f.old);assert.equal(f.trace.includes('create-connection'),false);
  assert.equal(f.owner.dnsSystemPlan.session,'b'.repeat(32));assert.equal(f.owner.dnsInternalRebuild,false);assert.equal(f.owner.backendStopInFlight,false);
});
for(const stage of ['path','destroy','stop'])test('user cancellation at '+stage+' prevents a new DNS session',async()=>{
  const f=fixture(),gate=deferred();f.gates.set(stage,gate);
  const pending=f.owner.rebuildDnsVpn(plan('a','new.test'));await flush();assert.ok(f.trace.includes(stage));f.wanted=false;gate.resolve();await pending;
  assert.equal(f.trace.includes('create-connection'),false);assert.equal(f.owner.backendStopInFlight,false);
  assert.ok(f.statuses.includes('VPN disconnected | DNS transition cancelled'));
});
test('active Taildrop or Taildrive transfer defers DNS rebuild without destroying TUN or consuming policy budget',async()=>{
  for(const flag of ['taildriveTransferInFlight','taildriveManualTransferInFlight','taildropSendInFlight','taildropReceiveInFlight']){
    const f=fixture();f.owner[flag]=true;f.owner.nextDnsBaseRefreshMs=99999;
    await f.owner.rebuildDnsVpn(plan('a','new.test'));
    assert.equal(f.timers,0,flag);
    assert.equal(f.trace.includes('destroy'),false,flag);
    assert.equal(f.trace.includes('stop'),false,flag);
    assert.equal(f.owner.vpnConnection,f.old,flag);
    assert.equal(f.owner.tunFd,7,flag);
    assert.equal(f.owner.nextDnsBaseRefreshMs,0,flag);
    assert.deepEqual(f.statuses.at(-1),{state:'reconfiguring',applied:true});
    assert.equal(f.owner.dnsRebuildPolicy.begin(JSON.stringify([['100.100.100.100'],['new.test']]),f.now),true,'deferred transfer must not consume rebuild budget');
  }
});
test('non-draining probe waits before destroy and keeps existing live TUN intact with reconnect_required',async()=>{
  const f=fixture();const initialPlan=f.owner.dnsSystemPlan;f.owner.sunshineProbeInFlight=true;
  await f.owner.rebuildDnsVpn(plan('a','new.test'));
  assert.ok(f.timers>0);
  assert.equal(f.trace.includes('destroy'),false);
  assert.equal(f.trace.includes('stop'),false);
  assert.equal(f.trace.includes('cleanup'),false);
  assert.equal(f.owner.vpnConnection,f.old);
  assert.equal(f.owner.tunFd,7);
  assert.equal(f.owner.dnsSystemPlan,initialPlan);
  assert.deepEqual(f.statuses.at(-1),{state:'reconnect_required',applied:true});
});
test('a completed old request drains first and then executes destroy -> stop -> start',async()=>{
  const f=fixture();let drainedBeforeDestroy=false;
  f.owner.sunshineProbeInFlight=true;
  f.onTimer=()=>{f.owner.sunshineProbeInFlight=false;};
  f.old.destroy=async()=>{drainedBeforeDestroy=!f.owner.sunshineProbeInFlight&&f.timers>0;return f.pause('destroy');};
  await f.owner.rebuildDnsVpn(plan('a','new.test'));
  assert.equal(drainedBeforeDestroy,true);
  assert.ok(f.trace.indexOf('destroy')<f.trace.indexOf('stop'));
  assert.ok(f.trace.indexOf('stop')<f.trace.indexOf('start'));
});
test('a concurrent explicit-stop owner keeps its stop flag after rebuild completion',async()=>{
  const f=fixture();f.owner.createProbeTun=async()=>{f.owner.backendStopInFlight=true;f.owner.explicitStopRequested=true;};
  await f.owner.rebuildDnsVpn(plan('a','new.test'));assert.equal(f.owner.backendStopInFlight,true);
});
test('a failed new DNS session recovers the tunnel without Tailnet DNS when fallback succeeds, and cleans up if fallback also fails',async()=>{
  const recovered=fixture();const recoveryFlags=[];
  recovered.owner.createProbeTun=async()=>{
    recoveryFlags.push(Boolean(recovered.owner.dnsRecoverWithoutTailnetDns));
    if(recovered.owner.dnsRecoverWithoutTailnetDns){
      recovered.owner.tunFd=11;
      recovered.owner.dnsSystemPlan=undefined;
      recovered.owner.currentVisibleStatus='OK | state=Running | tun=true';
    }else{
      recovered.owner.tunFd=-1;
      recovered.owner.dnsSystemPlan=undefined;
      recovered.owner.currentVisibleStatus='FAILED | VPN DNS | startup unavailable';
    }
  };
  await recovered.owner.rebuildDnsVpn(plan('a','new.test'));
  assert.deepEqual(recoveryFlags,[false,true]);
  assert.equal(recovered.owner.tunFd,11);
  assert.equal(recovered.owner.dnsSystemPlan,undefined);
  assert.equal(recovered.owner.currentVisibleStatus,'OK | state=Running | tun=true');
  assert.deepEqual(recovered.statuses.at(-1),{state:'unavailable',applied:false});

  const f=fixture();let attempts=0;
  f.owner.createProbeTun=async()=>{attempts++;f.owner.dnsSystemPlan=plan('b');f.owner.currentVisibleStatus='FAILED | VPN probe TUN | code=2200003';};
  await f.owner.rebuildDnsVpn(plan('a','new.test'));
  assert.equal(attempts,2);
  assert.ok(f.trace.includes('cleanup'));assert.equal(f.owner.dnsSystemPlan,undefined);assert.equal(f.owner.currentVisibleStatus,'FAILED | VPN DNS | reconfiguration unavailable');
});
test('zero physical DNS resolvers during refresh skip Go update and preserve the running tunnel',async()=>{
  const f=fixture();f.physical={networkId:3,resolvers:[]};
  f.owner.rebuildDnsVpn=async()=>assert.fail('zero resolvers must not trigger rebuild');
  await f.owner.refreshPhysicalDnsBase();
  assert.equal(f.trace.includes('update-base'),false);
  assert.equal(f.owner.dnsBaseFingerprint,JSON.stringify(f.physical));
  assert.deepEqual(f.statuses.at(-1),{state:'unavailable',applied:true});
});
test('DNS transition status never masks a real disconnect as connecting or preserves old Running',()=>{
  const f=fixture();f.owner.dnsInternalRebuild=true;
  f.owner.writeStatus('VPN disconnected | cancelled');assert.equal(f.owner.currentVisibleStatus,'VPN disconnected | cancelled');
  f.owner.writeStatus('VPN interface established | backend starting');assert.ok(f.owner.currentVisibleStatus.startsWith('VPN DNS restarting'));
  f.owner.writeStatus('OK | state=Running | tun=false');assert.equal(f.owner.currentVisibleStatus,'VPN DNS restarting');
  const vpnCtrl=read('services/VpnSessionController');const text=vpnCtrl.match(/^  preserveConfirmedVpnStatus\([\s\S]*?^  \}/m)[0];
  const box={};vm.runInNewContext(stripTypeScriptTypes('function '+text),box);assert.equal(box.preserveConfirmedVpnStatus.call({},f.owner.currentVisibleStatus,10000),false);
  f.owner.writeStatus('OK | state=Running | tun=true');assert.equal(f.owner.currentVisibleStatus,'OK | state=Running | tun=true');
});

function debugFixture() {
  const f={debug:true,now:20000,files:new Map(),calls:0};
  const box={BuildProfile:{get DEBUG(){return f.debug;}},Date:{now:()=>f.now},
    DiagnosticPrivacy:{runtimeStateCode:()=>1},
    fileIo:{accessSync:p=>f.files.has(p),statSync:p=>({size:f.files.get(p).length}),readTextSync:p=>f.files.get(p)},
    DnsRuntimeService:{sameConfiguration:(a,b)=>JSON.stringify([a.dnsAddresses,a.searchDomains])===JSON.stringify([b.dnsAddresses,b.searchDomains])}};
  vm.runInNewContext(stripTypeScriptTypes(method(source,'processDebugDnsRebuildRequest').replace('private async ','async function ')),box);
  f.owner={context:{filesDir:'/files'},dnsSystemPlan:plan(),lastDebugDnsRebuildRequest:0,currentVisibleStatus:'OK | state=Running',startupIntentAllowed:()=>true,
    writeTextFile:(p,t)=>f.files.set(p,t),writeAtomicTextFile:(p,t)=>f.files.set(p,t),
    rebuildDnsVpn:async p=>{f.calls++;assert.equal(p,f.owner.dnsSystemPlan);if(f.gate)await f.gate.promise;f.owner.dnsSystemPlan=plan('b');}};
  f.request=patch=>f.files.set('/files/dns-debug-rebuild-request.json',JSON.stringify({requestId:1,createdMs:f.now,...patch}));
  f.poll=()=>box.processDebugDnsRebuildRequest.call(f.owner);
  return f;
}

test('Debug rebuild command cannot operate in Release, after stop or during another transition',async()=>{
  for(const block of ['release','destroying','explicitStopRequested','backendStopInFlight','dnsRebuildInFlight','dnsBaseRefreshInFlight','no-intent','not-running','no-plan']){
    const f=debugFixture();f.request();
    if(block==='release')f.debug=false;
    else if(block==='no-intent')f.owner.startupIntentAllowed=()=>false;
    else if(block==='not-running')f.owner.currentVisibleStatus='starting';
    else if(block==='no-plan')f.owner.dnsSystemPlan=undefined;
    else f.owner[block]=true;
    await f.poll();assert.equal(f.calls,0,block);
  }
});
test('Debug rebuild commands expire, reject malformed requests and do not replay',async()=>{
  for(const patch of [{requestId:0},{requestId:1.5},{createdMs:1},{createdMs:30000},{ignored:'x'.repeat(600)}]){
    const f=debugFixture();f.request(patch);await f.poll();assert.equal(f.calls,0);
  }
  const f=debugFixture();f.request();await f.poll();f.request();await f.poll();assert.equal(f.calls,1);
});
test('Debug maintenance uses the existing plan and publishes only lifecycle booleans',async()=>{
  const f=debugFixture();f.request({resolvers:['attacker.test'],searchDomains:['override.test']});await f.poll();
  assert.deepEqual(JSON.parse(f.files.get('/files/dns-debug-rebuild-response.json')),{requestId:1,completed:true,sessionChanged:true,sameConfiguration:true,running:true,statusCode:1,tunPresent:false,failed:false,conflict:false,handoffFailed:false,dnsUnavailable:false,backendTimeout:false});
});
test('late Debug maintenance completion cannot publish after a stop',async()=>{
  const f=debugFixture();f.gate=deferred();f.request();const task=f.poll();await flush();f.owner.explicitStopRequested=true;f.gate.resolve();await task;
  assert.equal(f.files.has('/files/dns-debug-rebuild-response.json'),false);
});
