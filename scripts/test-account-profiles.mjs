import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

function loadVpnSessionController(scope) {
  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/ControlServerPresets',
    'services/AccountProfiles',
    'services/DeviceNameService',
    'services/AuthKeyLogin',
    'services/VpnAutoRecovery',
    'services/HomeReadOnlyGateway',
    'services/NetworkSettingsGateway',
    'services/SettingsPreferencesGateway',
    'services/TaildriveGateway'
  ], scope);
  const gwRaw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  const gwJs = stripTypeScriptTypes(gwRaw, { mode: 'transform' });
  vm.runInContext(
    `${gwJs}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    scope
  );
  loadEtsModules(['services/VpnSessionController'], scope);
}

const url='https://controlplane.tailscale.com', other='https://headscale.example.invalid';
function fixture(){
  const files=new Map();let failure='';
  const io={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},accessSync:p=>files.has(p),
    statSync:p=>{if(!files.has(p))throw Error('missing');return {size:Buffer.byteLength(files.get(p))};},
    readTextSync:p=>{if(!files.has(p))throw Error('missing');return files.get(p);},
    mkdirSync:p=>{files.set(p,'');},openSync:p=>{files.set(p,'');return {fd:p};},
    writeSync:(p,s)=>{files.set(p,s);return Buffer.byteLength(s)-(failure==='short'?1:0);},
    fsyncSync:()=>{if(failure==='sync')throw Error('sync');},closeSync(){},
    renameSync:(a,b)=>{if(failure==='rename')throw Error('rename');files.set(b,files.get(a));files.delete(a);},
    unlinkSync:p=>files.delete(p)};
  const scope={fileIo:io,setTimeout,clearTimeout,nativeBridge:{},vpnExtension:{},connection:{}};
  loadVpnSessionController(scope);
  const {AccountProfiles:p,ControlServerPresets:s,TaildriveGateway:G,ControlServerConfig:C}=scope;
  s.ensure('/files',url);p.ensure('/files',url);
  files.set('/files/control-server.json',JSON.stringify({controlURL:url,confirmed:true,updatedAtMs:1}));
  return {files,p,s,G,C,scope,fail:v=>{failure=v;}};
}
test('default slot preserves the existing native identity and cache paths',()=>{
  const f=fixture();f.files.set('/files/tailscale/control-original/tailscaled.state','PRIVATE-SENTINEL');
  assert.equal(f.p.stateRoot('/files',url,'default'),'/files/tailscale');
  assert.equal(f.p.cacheRoot('/files','/cache',url,'default'),'/cache');
  const id=f.p.add('/files',url);assert.equal(f.p.current('/files',url).activeId,'default');
  f.p.select('/files',url,id);f.p.select('/files',url,'default');
  assert.equal(f.files.get('/files/tailscale/control-original/tailscaled.state'),'PRIVATE-SENTINEL');
  assert.equal([...f.files.values()].filter(v=>v==='PRIVATE-SENTINEL').length,1);
});
test('same-server identities and file caches have disjoint stable roots',()=>{
  const f=fixture();const a=f.p.add('/files',url),b=f.p.add('/files',url);
  assert.notEqual(f.p.stateRoot('/files',url,a),f.p.stateRoot('/files',url,b));
  assert.equal(f.p.stateRoot('/files',url,a),'/files/tailscale/account-profiles/server-1/profile-1');
  const root=f.p.cacheRoot('/files','/cache',url,a);assert.notEqual(root,f.p.cacheRoot('/files','/cache',url,b));
  f.p.select('/files',url,b);f.p.select('/files',url,a);
  assert.equal(f.p.cacheRoot('/files','/cache',url,a),root);
});
test('same profile id on another server cannot share identity or caches',()=>{
  const f=fixture();f.s.ensure('/files',other);f.p.ensure('/files',other);
  const a=f.p.add('/files',url),b=f.p.add('/files',other);assert.equal(a,b);
  assert.notEqual(f.p.stateRoot('/files',url,a),f.p.stateRoot('/files',other,b));
  assert.notEqual(f.p.cacheRoot('/files','/cache',url,a),f.p.cacheRoot('/files','/cache',other,b));
  f.p.select('/files',url,a);assert.equal(f.p.current('/files',other).activeId,'default');
});
for(const failure of ['short','sync','rename'])test(`${failure} failure preserves prior active account and catalog`,()=>{
  const f=fixture(),id=f.p.add('/files',url);const before=f.files.get('/files/account-profiles-v1.json');f.fail(failure);
  assert.throws(()=>f.p.select('/files',url,id));assert.equal(f.files.get('/files/account-profiles-v1.json'),before);
  assert.equal(f.p.current('/files',url).activeId,'default');assert.equal(f.files.has('/files/account-profiles-v1.json.tmp'),false);
  assert.equal([...f.files.keys()].some(k=>k.endsWith('.tmp')),false);
});
test('malformed catalog fails closed instead of falling back to legacy identity',()=>{
  const f=fixture();f.files.set('/files/account-profiles-v1.json','{bad');
  assert.throws(()=>f.p.ensure('/files',url));assert.throws(()=>f.p.stateRoot('/files',url,'default'));
  assert.throws(()=>f.p.cacheRoot('/files','/cache',url,'default'));
});
test('unknown and traversal profile ids cannot select or construct paths',()=>{
  const f=fixture();for(const id of ['../default','profile-9','', '/other']){
    assert.throws(()=>f.p.select('/files',url,id));assert.throws(()=>f.p.stateRoot('/files',url,id));
  }assert.equal(f.p.current('/files',url).activeId,'default');
});
test('Unicode account label persists without changing the request ownership token',()=>{
  const f=fixture();const token=f.p.token('/files',url);
  f.p.setLabel('/files',url,'default','用户@example.test');
  assert.equal(f.p.current('/files',url).profiles[0].label,'用户@example.test');assert.equal(f.p.token('/files',url),token);
});
test('A to B to A never revives the old ownership token, even in the same millisecond',()=>{
  const f=fixture();const id=f.p.add('/files',url),before=f.p.token('/files',url);
  f.p.select('/files',url,id);const mid=f.p.token('/files',url);f.p.select('/files',url,'default');
  assert.notEqual(f.p.token('/files',url),before);assert.notEqual(f.p.token('/files',url),mid);
});
test('profile count limit rejects new slots without changing existing ones',()=>{
  const f=fixture();for(let i=0;i<15;i++)f.p.add('/files',url);
  assert.throws(()=>f.p.add('/files',url),/limit/);assert.equal(f.p.current('/files',url).profiles.length,16);
});
test('late account label cannot rename a different active profile',()=>{
  const f=fixture(),id=f.p.add('/files',url);f.p.select('/files',url,id);
  assert.throws(()=>f.p.setLabel('/files',url,'default','old@example.test'),/changed/);
  assert.equal(f.p.current('/files',url).profiles[1].label,'');
});

for(const roundTrip of [false,true])test(`queued file mutation rejects account switch; roundTrip=${roundTrip}`,async()=>{
  const f=fixture(),id=f.p.add('/files',url),g=new f.G();g.configure({filesDir:'/files'});let release;const writes=[];
  g.queryQueue=new Promise(r=>{release=r;});g.writeText=(p,s)=>{writes.push(p);return true;};
  const pending=g.mutate({operation:'delete',path:'/original-account-file'});
  f.p.select('/files',url,id);if(roundTrip)f.p.select('/files',url,'default');
  release();await assert.rejects(pending,/not configured/);assert.equal(writes.length,0);
});
test('reconfiguring a browser cannot revive its queued operation',async()=>{
  const f=fixture(),g=new f.G();g.configure({filesDir:'/files'});let release;g.queryQueue=new Promise(r=>{release=r;});
  const pending=g.list('/');g.configure({filesDir:'/files'});release();await assert.rejects(pending,/account changed/);
});
test('late file response is rejected after an account round trip without clearing new-session IPC',async()=>{
  const f=fixture(),id=f.p.add('/files',url),g=new f.G();let poll;f.scope.setTimeout=fn=>{poll=fn;};
  g.configure({filesDir:'/files'});let writes=0;g.writeText=()=>{writes++;return true;};
  const pending=g.performVpnExtensionRequest('query','list','/',10000);const before=writes;
  f.p.select('/files',url,id);f.p.select('/files',url,'default');poll();await assert.rejects(pending,/server changed/);assert.equal(writes,before);
});

function controller(){
  const f=fixture(),events=[];let stop;
  const state={
    lifecycleGeneration:1,controlServerURL:url,controlServerConfirmed:true,accountProfileId:'default',
    accountProfiles:[],accountProfileStatus:'',backendStatus:'OK',vpnStatus:'HarmonyOS VPN Extension Stopped',
    controlServerSwitching:false,disconnectInProgress:false,loginInProgress:false,logoutInProgress:false,
    taildropReceiveInProgress:false,taildropMediaSaveInProgress:false,cacheClearInProgress:false,
    diagnosticActionInProgress:false,routeAllUpdateInProgress:false,exitNodeUpdateInProgress:false,
    exitNodeLanUpdateInProgress:false,connectInProgress:false,loginHandoffStatus:'Secure Login Pending'
  };
  const host={
    getFilesDir:()=>'/files',getCacheDir:()=>'/cache',getLifecycleGeneration:()=>state.lifecycleGeneration,
    isAppShellReady:()=>true,isAppLockRequired:()=>false,isLogoutInProgress:()=>state.logoutInProgress,
    isDiagnosticActionInProgress:()=>state.diagnosticActionInProgress,isCacheClearInProgress:()=>state.cacheClearInProgress,
    isTaildropSendActive:()=>false,isTaildropReceiveInProgress:()=>state.taildropReceiveInProgress,
    isTaildropMediaSaveInProgress:()=>state.taildropMediaSaveInProgress,shouldPollHealthFast:()=>false,
    getBackendStatus:()=>state.backendStatus,setBackendStatus:s=>{state.backendStatus=s;},
    getVpnStatus:()=>state.vpnStatus,setVpnStatus:s=>{state.vpnStatus=s;},
    isBackendReady:()=>true,setBackendReady(){},isBackendInitializationVisible:()=>false,setBackendInitializationVisible(){},
    setDevicesLoading(){},hasAuthenticatedSession:()=>false,setHasAuthenticatedSession(){},
    isConnectInProgress:()=>state.connectInProgress,setConnectInProgressState:v=>{state.connectInProgress=v;},
    isDisconnectInProgress:()=>state.disconnectInProgress,setDisconnectInProgress:v=>{state.disconnectInProgress=v;},
    isLoginInProgress:()=>state.loginInProgress,setLoginInProgress:v=>{state.loginInProgress=v;},
    getLoginHandoffStatus:()=>state.loginHandoffStatus,setLoginHandoffStatus:s=>{state.loginHandoffStatus=s;},
    setLoginPromptKind(){},isAuthKeyLoginVisible:()=>false,setAuthKeyLoginVisible(){},
    getAuthKeyInput:()=>'',setAuthKeyInput(){},getAuthKeyStatus:()=>'',setAuthKeyStatus(){},
    isControlServerConfirmed:()=>state.controlServerConfirmed,setControlServerConfirmed:v=>{state.controlServerConfirmed=v;},
    getControlServerURL:()=>state.controlServerURL,setControlServerURL:u=>{state.controlServerURL=u;},
    setControlServerInput(){},setControlServerStatus(){},setControlServerEditorVisible(){},setControlServerPresets(){},
    isControlServerSwitching:()=>state.controlServerSwitching,setControlServerSwitching:v=>{state.controlServerSwitching=v;},
    getAccountProfileId:()=>state.accountProfileId,setAccountProfileId:id=>{state.accountProfileId=id;},
    getAccountProfiles:()=>state.accountProfiles,setAccountProfiles:p=>{state.accountProfiles=p;},
    setAccountProfileStatus:s=>{state.accountProfileStatus=s;},
    getPeers:()=>[],onPeersUpdated(){},onPeerPresenceInvalidated(){},setMeshArcReceiver(){},
    setAccountSummary(){},setAvatarLoadFailed(){},getExitNodes:()=>[],setExitNodes(){},
    isExitNodeUpdateInProgress:()=>state.exitNodeUpdateInProgress,setExitNodeUpdateInProgress(){},
    isExitNodeStatusFailed:()=>false,setExitNodeNoneStatus(){},setExitNodeSelectedStatus(){},
    setExitNodeUnavailableStatus(){},setExitNodeRawStatus(){},getNetworkSettings:()=>({routeAll:true,exitNodeAllowLANAccess:false}),
    setNetworkSettings(){},setNetworkSettingStatus(){},isRouteAllUpdateInProgress:()=>state.routeAllUpdateInProgress,
    setRouteAllUpdateInProgress(){},isExitNodeLanUpdateInProgress:()=>state.exitNodeLanUpdateInProgress,
    setExitNodeLanUpdateInProgress(){},setTrafficDownloadBytes(){},setTrafficUploadBytes(){},
    setTrafficDownloadRate(){},setTrafficUploadRate(){},getTrafficSamples:()=>[],setTrafficSamples(){},
    isVpnConflictDialogVisible:()=>false,setVpnConflictDialogVisible(){},showVpnConflictAlertDialog(){},
    syncHomeTitleCompact(){},setHomeTitleCompact(){},deviceModel:()=>'Test',harmonyOSHostinfoVersion:()=>'6.0',
    openControlServerSettings(){},openSecureLoginBrowser:async()=>{},confirmControlServerSelection:()=>undefined,
    invalidateAccountGuard(){},clearControlServerShellState:()=>events.push('clear'),
    reloadTaildropStorageForActiveIdentity(){},resetTaildropSnapshot(){},applyBackendTaildropSnapshot(){},
    onLiveExtensionTick(){},resetStreamingStatesForDisconnect(){},autoProbeConnectedPeerServices(){},
    syncOfflinePeerStatusRefreshPolling(){},syncWindowPrivacyMode(){},logServiceStatusIfChanged(){},
    scheduleLifecycleTask:()=>-1,recordDiagnosticEvent(){}
  };
  const ctrl=new f.scope.VpnSessionController(host,{
    vpnCommandGateway:{stopBackend:()=>{events.push('stop');return new Promise(r=>{stop=r;});}},
    vpnAutoRecovery:{cancel(){},save(){},wanted:()=>false,armed:()=>false}
  });
  ctrl.startBackend=()=>{events.push(`start:${state.accountProfileId}`);state.backendStatus='OK';};
  return {...f,c:ctrl,state,events,stop:v=>stop(v)};
}
test('new account waits for old stop and duplicate taps create just one slot',async()=>{
  const f=controller();f.c.persistAccountProfile('',true);const task=f.c.backendRestartPromise;f.c.persistAccountProfile('',true);
  assert.equal(f.p.current('/files',url).profiles.length,2);assert.equal(f.p.current('/files',url).activeId,'default');
  f.stop('OK');await task;await Promise.resolve();assert.deepEqual(f.events,['stop','clear','start:profile-1']);assert.equal(f.state.controlServerSwitching,false);
});
test('stop failure leaves old account active and available',async()=>{
  const f=controller(),id=f.p.add('/files',url);const task=f.c.switchAccountProfile(id,false);f.stop('FAILED');await task;
  assert.equal(f.p.current('/files',url).activeId,'default');assert.deepEqual(f.events,['stop']);assert.equal(f.state.accountProfileStatus,'failed');
});
test('selection write failure restarts the original account',async()=>{
  const f=controller(),id=f.p.add('/files',url);const task=f.c.switchAccountProfile(id,false);f.fail('rename');f.stop('OK');await task;
  assert.equal(f.p.current('/files',url).activeId,'default');assert.deepEqual(f.events,['stop','start:default']);
});
test('disposed controller cannot commit an account switch',async()=>{
  const f=controller(),id=f.p.add('/files',url);const task=f.c.switchAccountProfile(id,false);f.state.lifecycleGeneration++;f.stop('OK');await task;
  assert.equal(f.p.current('/files',url).activeId,'default');assert.deepEqual(f.events,['stop']);
});
test('VPN and active operations block account switches',()=>{
  for(const field of ['controlServerSwitching','disconnectInProgress','loginInProgress','logoutInProgress','taildropReceiveInProgress']){
    const f=controller();f.state[field]=true;f.c.persistAccountProfile('',true);assert.equal(f.p.current('/files',url).profiles.length,1);
  }
  const fRecovery=controller();fRecovery.c.vpnFailedExtensionRecoveryInFlight=true;fRecovery.c.persistAccountProfile('',true);
  assert.equal(fRecovery.p.current('/files',url).profiles.length,1);
  const fConnected=controller();fConnected.state.vpnStatus='OK | state=Running';fConnected.c.persistAccountProfile('',true);
  assert.equal(fConnected.p.current('/files',url).profiles.length,1);
});

test('abandoned browser login can release switching without cancelling an auth-key request',()=>{
  const f=controller();
  const cmdId=f.c.vpnCommandStateMachine.begin(f.scope.VpnCoreCommand.LOGIN);
  f.c.loginCommandId=cmdId;
  f.state.loginInProgress=true;
  f.state.loginHandoffStatus='Secure login page opened';
  let completed=0;
  const origFinish=f.c.finishSecureLogin.bind(f.c);
  f.c.finishSecureLogin=(id,status)=>{assert.equal(id,cmdId);assert.equal(status,'Secure Login Pending');completed++;origFinish(id,status);};
  f.c.stopWaitingForAccountLogin();assert.equal(completed,1);
  assert.equal(f.state.loginInProgress,false);
  f.state.loginInProgress=true;
  f.state.loginHandoffStatus='Auth key login pending';
  f.c.stopWaitingForAccountLogin();assert.equal(completed,1);
});
