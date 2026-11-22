import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const shell=read('entry/src/main/ets/components/BridgeStatus.ets');
const taildropCtrl=read('entry/src/main/ets/services/TaildropSessionController.ets');
const vpn=read('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets');
function load(source,name,sandbox) {
  const method=source.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}','m'))?.[0];
  assert.ok(method,name);
  vm.runInNewContext(stripTypeScriptTypes(method.replace(/^  (?:private )?async /,'async function ').replace(/^  (?:private )?/,'function ')),sandbox);
  return sandbox[name];
}
test('the release permission contract needs neither gallery-write nor persistent-file ACL',()=>{
  const manifest=JSON.parse(read('entry/src/main/module.json5')).module;
  const permissions=manifest.requestPermissions.map(p=>p.name);
  assert.ok(permissions.includes('ohos.permission.INTERNET'));
  assert.ok(!permissions.includes('ohos.permission.WRITE_IMAGEVIDEO'));
  assert.ok(!permissions.includes('ohos.permission.FILE_ACCESS_PERSIST'));
  for(const source of [shell,taildropCtrl,vpn])assert.doesNotMatch(source,/AutomaticFileSaver|AutoSaveSettings|auto-save-.*toggle|persistPermission|activatePermission/);
  assert.equal(manifest.abilities[0].skills.some(s=>s.actions.includes('ohos.want.action.sendData')),true);
});
test('media content is copied only after system consent; cancellation preserves the inbox original',async()=>{
  for(const approved of [true,false]) {
    let resolve;const gate=new Promise(r=>{resolve=r;});const copies=[];
    const sandbox={photoAccessHelper:{PhotoType:{IMAGE:1},getPhotoAccessHelper:()=>({showAssetsCreationDialog:()=>gate})},
      fileUri:{getUriFromPath:p=>'file://'+p}};
    const save=load(taildropCtrl,'exportTaildropImageToGallery',sandbox);
    const state={taildropFileExtension:()=> 'jpg',resolveTaildropMediaType:()=>1,
      host:{getAbilityContext:()=>({})},taildropGalleryAssetTitle:()=> 'photo',
      copyTaildropStagedFile:async(...args)=>{copies.push(args);return true;}};
    const pending=save.call(state,{name:'photo.jpg',path:'/private/photo',size:8});
    assert.equal(copies.length,0);
    resolve(approved?['file://media/approved']:[]);
    assert.equal(await pending,approved);
    assert.equal(copies.length,approved?1:0);
    if(approved)assert.deepEqual(copies[0],['/private/photo','file://media/approved',8]);
  }
});
test('document save returns only a system-selected URI and cancellation clears picker busy state',async()=>{
  for(const response of [[],['file://docs/chosen'],null]) {
    const sandbox={picker:{DocumentSaveOptions:class{},DocumentViewPicker:class{
      async save(){if(response===null)throw Error('cancelled');return response;}
    }},sanitizeTaildropFileName:x=>x};
    const choose=load(taildropCtrl,'selectTaildropReceiveDestination',sandbox);
    const state={taildropPickerOpen:false,setTaildropPickerOpen(v){this.taildropPickerOpen=v;},
      host:{getAbilityContext:()=>({}),showTaildropToast(){}}};
    assert.equal(await choose.call(state,{name:'doc.txt'}),response?.[0]??'');
    assert.equal(state.taildropPickerOpen,false);
  }
});
test('new media and documents both prompt once and a stopped extension emits no save prompt',()=>{
  const prompts=[];
  const sandbox={publishTaildropSavePrompt:(_,name)=>prompts.push(name)};
  const notify=load(vpn,'updateTaildropNotifications',sandbox);
  const state={context:{},updateTaildropProgressNotification(){},
    validTaildropWaitingFile:f=>f.size>=0,taildropInboxNotificationKey:f=>f.name+f.size,
    notifiedTaildropInboxKeys:[],taildropInboxNotificationInitialized:false};
  const snapshot={state:'ready',inboxReason:'',waitingFiles:[],incomingFiles:[]};
  notify.call(state,snapshot);
  snapshot.waitingFiles=[{name:'photo.jpg',size:8},{name:'doc.txt',size:4}];
  notify.call(state,snapshot);notify.call(state,snapshot);
  assert.deepEqual(prompts,['photo.jpg','doc.txt']);
  state.explicitStopRequested=true;snapshot.waitingFiles.push({name:'later.jpg',size:8});
  notify.call(state,snapshot);assert.equal(prompts.length,2);
});
