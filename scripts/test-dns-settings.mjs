import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { isIP } from 'node:net';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';
const read = path => readFileSync(new URL('../entry/src/main/ets/' + path + '.ets', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
function fixture() {
 const f={files:new Map(),handles:new Map(),next:0,fail:''};
 const box={fileIo:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},
  accessSync:p=>f.files.has(p),statSync:p=>({size:Buffer.byteLength(f.files.get(p))}),readTextSync:p=>f.files.get(p),
  openSync:p=>{if(f.fail==='open')throw Error('disk');const fd=++f.next;f.handles.set(fd,p);f.files.set(p,'');return {fd};},
  writeSync:(fd,text)=>{const value=f.fail==='short'?text.slice(0,12):text;f.files.set(f.handles.get(fd),value);return Buffer.byteLength(value);},
  fsyncSync:()=>{if(f.fail==='sync')throw Error('sync');},closeSync:file=>f.handles.delete(file.fd),
  renameSync:(a,b)=>{if(f.fail==='rename')throw Error('rename');f.files.set(b,f.files.get(a));f.files.delete(a);},unlinkSync:p=>f.files.delete(p)}};
 loadEtsModules(['services/AtomicFileStore', 'services/DnsSettings'], box, { Store: 'DnsSettingsStore' });
 f.store=box.Store;return f;
}
const configured=()=>({enabled:true,primary:'192.0.2.53',secondary:'2001:db8::53',searchDomains:['corp.test']});
test('custom DNS defaults off; corrupt, oversized and future settings do not enable it',()=>{
 const f=fixture(),s=f.store;assert.equal(s.load('/files').enabled,false);
 for(const text of ['{', 'x'.repeat(8193),JSON.stringify({...configured(),schemaVersion:2})]) {
  f.files.set('/files/dns-settings.json',text);assert.equal(s.load('/files').enabled,false);
 }
});
test('complete IPv6 parsing rejects an IPv4 tail before compression',()=>{
 const {store:s}=fixture();
 for(const ip of ['192.0.2.1::','192.0.2.1::abcd','1:192.0.2.1::','2001:db8:::1','1:2:3:4:5:6:7:8:9']) {
  assert.equal(isIP(ip),0);assert.equal(s.isValidAddress(ip),false,ip);
 }
 for(const ip of ['192.0.2.53','2001:db8::53','2001:db8:1:2:3:4:5:6','2001:db8::192.0.2.53']) assert.equal(s.isValidAddress(ip),true,ip);
});
test('unusable or recursive upstreams are rejected, including expanded Quad100',()=>{
 const {store:s}=fixture();
 for(const ip of ['0.0.0.0','127.0.0.1','255.255.255.255','224.0.0.1','169.254.1.53','::','::1','ff02::1','fe80::53','100.100.100.100','fd7a:115c:a1e0:0:0:0:0:53','::ffff:127.0.0.1']) assert.equal(s.isValidAddress(ip),false,ip);
});
test('IPv6-only upstream stays enabled and reaches the engine without TUN-family filtering',()=>{
 const {store:s}=fixture(),value={enabled:true,primary:'2001:db8::53',secondary:'',searchDomains:[]};
 assert.ok(s.normalize(value));assert.deepEqual(plain(s.upstreams(value)),[value.primary]);
 assert.deepEqual(plain(s.upstreams({...value,enabled:false})),[]);
});
test('search normalization, limits and malformed persisted fields',()=>{
 const {store:s}=fixture();assert.deepEqual(plain(s.parseSearchDomains('Corp.Test, corp.test., custom.test')),['corp.test','custom.test']);
 for(const value of [['bad_domain.test'],['a..test'],['a'.repeat(64)+'.test'],Array(9).fill('corp.test')]) assert.equal(s.normalize({...configured(),searchDomains:value}),undefined);
 assert.equal(s.normalize({...configured(),primary:''}),undefined);
 assert.equal(s.normalize({...configured(),enabled:'true'}),undefined);
});
test('settings round-trip, preserve disabled values, and do not mutate Tailnet preferences',()=>{
 const f=fixture(),s=f.store;f.files.set('/files/tailnet-dns-preferences-v1.json','unchanged');
 assert.ok(s.save('/files',configured()));assert.equal(s.load('/files').enabled,true);
 assert.ok(s.save('/files',{...configured(),enabled:false}));assert.equal(s.load('/files').primary,'192.0.2.53');
 assert.equal(f.files.get('/files/tailnet-dns-preferences-v1.json'),'unchanged');
});
for(const fail of ['open','short','sync','rename']) test('failed '+fail+' keeps prior DNS settings and reports failure',()=>{
 const f=fixture(),s=f.store;assert.ok(s.save('/files',configured()));const previous=f.files.get('/files/dns-settings.json');f.fail=fail;
 assert.equal(s.save('/files',{...configured(),enabled:false}),undefined);assert.equal(f.files.get('/files/dns-settings.json'),previous);
 assert.equal(s.load('/files').enabled,true);assert.equal(f.handles.size,0);
 assert.equal([...f.files.keys()].some(k=>k.endsWith('.tmp')),false);
});
test('custom DNS save is gated by the real foreground/security/connection guard',()=>{
 const source=read('components/BridgeStatus'),method=name=>source.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  }','m'))[0];
 const box={DnsSettingsStore:fixture().store,$r:x=>x};
 vm.runInNewContext(stripTypeScriptTypes('class Owner{'+method('canEditCustomDns')+method('saveCustomDns')+'}\nglobalThis.Owner=Owner;'),box);
 const c=new box.Owner();Object.assign(c,{appShellReady:true,remoteStreamAppInForeground:true,securityPreferencesReady:true,appLockRequired:false,appLockAuthenticating:false,securitySettingsAuthenticating:false,isConnected:()=>false,isConnecting:()=>false,isAuthenticated:()=>true,dnsSettingsEnabled:true,dnsPrimaryInput:'192.0.2.53',dnsSecondaryInput:'',dnsSearchDomainsInput:''});
 let writes=0;box.DnsSettingsStore.save=()=>{writes++;return configured();};c.getUIContext=()=>({getHostContext:()=>({filesDir:'/files'})});
 for(const flag of ['appShellReady','remoteStreamAppInForeground','securityPreferencesReady']) {c[flag]=false;c.saveCustomDns();assert.equal(writes,0);c[flag]=true;}
 for(const flag of ['appLockRequired','appLockAuthenticating','securitySettingsAuthenticating']) {c[flag]=true;c.saveCustomDns();assert.equal(writes,0);c[flag]=false;}
 for(const flag of ['isConnected','isConnecting']) {c[flag]=()=>true;c.saveCustomDns();assert.equal(writes,0);c[flag]=()=>false;}
 c.isAuthenticated=()=>false;c.saveCustomDns();assert.equal(writes,0);c.isAuthenticated=()=>true;
 c.saveCustomDns();assert.equal(writes,1);assert.equal(c.dnsSettingsStatus,'saved');
});
