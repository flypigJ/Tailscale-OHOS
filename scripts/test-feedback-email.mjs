import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source=readFileSync(new URL('../entry/src/main/ets/services/FeedbackEmailGateway.ets',import.meta.url),'utf8')
  .replace(/^import .*;\r?\n/gm,'').replace('export class FeedbackEmailGateway','class FeedbackEmailGateway');
const name='TailscaleOHOS-Diagnostic-20261105-150000-001.zip';
function fixture(){
  const f={calls:[],failures:[],size:1024,isFile:true};
  const scope={encodeURI,wantConstant:{Flags:{FLAG_AUTH_READ_URI_PERMISSION:1}},
    fileIo:{statSync:()=>{if(f.missing)throw Error('missing');return {size:f.size,isFile:()=>f.isFile};}},
    fileUri:{getUriFromPath:path=>'file://test'+path}};
  vm.runInNewContext(stripTypeScriptTypes(source)+'\nglobalThis.Gateway=FeedbackEmailGateway;',scope);
  f.gateway=new scope.Gateway();f.report={path:'/cache/'+name,fileName:name,size:1024};
  f.context={cacheDir:'/cache',startAbilityByType:(...args)=>{
    f.calls.push(args);if(f.syncError)throw Error('sync');
    if(f.earlyError)args[2].onError(16000001,'resolver','private error');
    return f.reject?Promise.reject(Error('rejected')):Promise.resolve();
  }};
  f.open=()=>f.gateway.open(f.context,f.report,'feedback@example.test','反馈 1.1.6 (100000016)','问题：\n步骤 & 时间',code=>f.failures.push(code));
  return f;
}
test('mail contract supplies encoded recipient, subject, body and read-only ZIP URI',async()=>{
  const f=fixture();await f.open();assert.equal(f.calls.length,1);
  const [type,p]=f.calls[0];assert.equal(type,'mail');assert.equal(p.sceneType,1);
  assert.equal(p.email[0],encodeURI('feedback@example.test'));
  assert.equal(decodeURI(p.subject),'反馈 1.1.6 (100000016)');assert.equal(decodeURI(p.body),'问题：\n步骤 & 时间');
  assert.equal(decodeURI(p['ability.params.stream'][0]),'file://test/cache/'+name);
  assert.equal(p['ability.want.params.uriPermissionFlag'],1);
  assert.equal(Object.keys(p).some(k=>/sendNow|password|authKey/.test(k)),false);
});
for(const kind of ['path','filename','empty','size','directory','missing'])test('invalid '+kind+' attachment is never handed off',async()=>{
  const f=fixture();if(kind==='path')f.report.path='/private/secret.zip';if(kind==='filename')f.report.fileName='../'+name;
  if(kind==='empty')f.report.size=0;if(kind==='size')f.size=100;if(kind==='directory')f.isFile=false;if(kind==='missing')f.missing=true;
  await assert.rejects(f.open());assert.equal(f.calls.length,0);
});
for(const mode of ['syncError','reject','earlyError'])test('mail '+mode+' remains a failure',async()=>{
  const f=fixture();f[mode]=true;await assert.rejects(f.open());
  assert.equal(f.calls.length,1);
});
test('late resolver and completion errors report a sanitized code only once',async()=>{
  const f=fixture();await f.open();const callback=f.calls[0][2];
  callback.onError(16000001,'private name','private message');
  callback.completionHandler.onRequestFailure('private name',16000001,'private message');
  assert.deepEqual(f.failures,[16000001]);
});
test('composer cancellation and request success do not report a message as sent',async()=>{
  const f=fixture();await f.open();const callback=f.calls[0][2];
  callback.completionHandler.onRequestSuccess('mail');callback.onResult({resultCode:0});callback.onResult({resultCode:-1});
  callback.completionHandler.onRequestFailure('',1,'user cancelled');
  assert.equal(f.calls.length,1);assert.equal(f.failures.length,0);
});

const templateScope={};
const templateSource=readFileSync(new URL('../entry/src/main/ets/services/FeedbackEmailTemplate.ets',import.meta.url),'utf8')
  .replace(/^import .*;\r?\n/gm,'').replace('export class FeedbackEmailTemplate','class FeedbackEmailTemplate');
vm.runInNewContext(stripTypeScriptTypes(templateSource)+'\nglobalThis.Template=FeedbackEmailTemplate;',templateScope);
const render=templateScope.Template.render;
const context={appVersion:'1.1.6',appVersionCode:100000016,tailscaleVersion:'1.104.5',model:'Test Phone',
  system:'HarmonyOS / 7.0',sdkApiVersion:26,generatedAt:'2026-11-05T08:00:00.000Z',
  signedIn:true,exitNodeSelected:false,acceptSubnetRoutes:true,account:'private-user',token:'private-token'};
for(const locale of ['base','zh_CN'])test('issue template '+locale+' fills environment without asking users to copy logs',()=>{
  const entries=JSON.parse(readFileSync(new URL('../entry/src/main/resources/'+locale+'/element/string.json',import.meta.url),'utf8')).string;
  const get=name=>entries.find(e=>e.name===name).value;
  const body=render(get('feedback_email_body'),context,get('feedback_email_yes'),get('feedback_email_no'),get('feedback_email_unknown'));
  assert.match(body,/1\.1\.6/);assert.match(body,/100000016/);assert.match(body,/1\.104\.5/);
  assert.match(body,/Test Phone/);assert.match(body,/HarmonyOS \/ 7\.0/);assert.match(body,/26/);
  assert.match(body,/2026-11-05T08:00:00.000Z/);assert.match(body,/UTC/);
  assert.doesNotMatch(body,/\{[a-zA-Z]+\}|%[sd]|private-user|private-token/);
  assert.ok(body.includes(get('feedback_email_yes'))&&body.includes(get('feedback_email_no')));
  assert.equal((body.match(/^\d\./gm)||[]).length,3);
});
test('missing template context stays unknown, never fabricating sign-in or settings',()=>{
  assert.equal(render('{model}|{sdkApiVersion}|{signedIn}|{exitNodeSelected}|{account}',undefined,'Y','N','?'),'?|?|?|?|?');
  assert.equal(render('{sdkApiVersion}',{sdkApiVersion:NaN},'Y','N','?'),'?');
});
test('template values are bounded, single-line and never recursively expanded',()=>{
  const body=render('{model}|{system}|{account}',{model:'{signedIn}\nname',system:'a'.repeat(500),signedIn:true,account:'secret'},'Y','N','?');
  assert.equal(body,'{signedIn} name|'+'a'.repeat(200)+'|?');
});
