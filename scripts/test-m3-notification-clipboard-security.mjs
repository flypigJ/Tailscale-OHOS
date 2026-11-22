import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource,
  stripEtsModuleSyntax
} from './helpers/ets-vm-loader.mjs';

const REPO_ROOT = new URL('../', import.meta.url);
const readRepoFile = rel => readFileSync(new URL(rel, REPO_ROOT), 'utf8').replace(/\r\n/g, '\n');

function extractMethod(source, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm').exec(source);
  assert.ok(match, `missing method ${name}`);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end > match.index, `missing closing brace for ${name}`);
  return source.slice(match.index, end + 4);
}

function createDirectoryAwareFileIo() {
  const mem = createMemoryFileIo();
  const dirs = new Set(['/data', '/data/files', '/data/cache']);
  const symlinks = new Map();

  const normalize = p => String(p).replace(/\/+$/, '') || '/';
  const ensureParents = p => {
    const parts = normalize(p).split('/').filter(Boolean);
    let cur = '';
    for (let i = 0; i < parts.length - 1; i++) {
      cur += `/${parts[i]}`;
      dirs.add(cur);
    }
  };

  const baseOpenSync = mem.fileIo.openSync.bind(mem.fileIo);
  const baseRenameSync = mem.fileIo.renameSync.bind(mem.fileIo);
  const baseUnlinkSync = mem.fileIo.unlinkSync.bind(mem.fileIo);

  const fileIo = {
    ...mem.fileIo,
    accessSync(path) {
      const clean = normalize(path);
      return mem.files.has(clean) || dirs.has(clean) || symlinks.has(clean);
    },
    async access(path) {
      return fileIo.accessSync(path);
    },
    async stat(path) {
      return fileIo.statSync(path);
    },
    async readText(path) {
      return mem.fileIo.readTextSync(normalize(path));
    },
    mkdirSync(path) {
      const clean = normalize(path);
      ensureParents(clean);
      dirs.add(clean);
    },
    openSync(path, mode) {
      const clean = normalize(path);
      ensureParents(clean);
      return baseOpenSync(clean, mode);
    },
    renameSync(from, to) {
      const cleanFrom = normalize(from);
      const cleanTo = normalize(to);
      ensureParents(cleanTo);
      return baseRenameSync(cleanFrom, cleanTo);
    },
    statSync(path) {
      const clean = normalize(path);
      if (symlinks.has(clean)) {
        const target = symlinks.get(clean);
        return fileIo.statSync(target);
      }
      if (dirs.has(clean) && !mem.files.has(clean)) {
        return {
          size: 0,
          mtime: 1000,
          isFile: () => false,
          isDirectory: () => true,
          isSymbolicLink: () => false
        };
      }
      return mem.fileIo.statSync(clean);
    },
    lstatSync(path) {
      const clean = normalize(path);
      if (symlinks.has(clean)) {
        return {
          size: 0,
          mtime: 1000,
          isFile: () => false,
          isDirectory: () => false,
          isSymbolicLink: () => true
        };
      }
      return fileIo.statSync(clean);
    },
    listFileSync(dirPath) {
      const base = normalize(dirPath);
      const prefix = `${base}/`;
      const names = new Set();
      for (const key of [...mem.files.keys(), ...dirs, ...symlinks.keys()]) {
        if (key.startsWith(prefix)) {
          const rest = key.slice(prefix.length);
          if (rest.length > 0) {
            const slash = rest.indexOf('/');
            names.add(slash >= 0 ? rest.slice(0, slash) : rest);
          }
        }
      }
      return [...names];
    },
    unlinkSync(path) {
      const clean = normalize(path);
      if (symlinks.has(clean)) {
        symlinks.delete(clean);
        return;
      }
      baseUnlinkSync(clean);
    },
    rmdirSync(dirPath) {
      const clean = normalize(dirPath);
      const prefix = `${clean}/`;
      for (const f of [...mem.files.keys()]) {
        if (f.startsWith(prefix)) mem.files.delete(f);
      }
      for (const s of [...symlinks.keys()]) {
        if (s.startsWith(prefix)) symlinks.delete(s);
      }
      for (const d of [...dirs]) {
        if (d === clean || d.startsWith(prefix)) dirs.delete(d);
      }
    }
  };

  return {
    mem,
    dirs,
    symlinks,
    fileIo,
    writeFile(path, content) {
      const clean = normalize(path);
      ensureParents(clean);
      const buf = Buffer.from(content, 'utf8');
      mem.rawBytes.set(clean, buf);
      mem.files.set(clean, content);
    },
    addSymlink(linkPath, targetPath) {
      const clean = normalize(linkPath);
      ensureParents(clean);
      symlinks.set(clean, normalize(targetPath));
    }
  };
}

function createPasteboardRecorder() {
  const clipboardWrites = [];
  const SHARE_LOCAL = 1;
  const pasteboard = {
    MIMETYPE_TEXT_PLAIN: 'text/plain',
    ShareOption: { INAPP: 0, LOCALDEVICE: SHARE_LOCAL, CROSSDEVICE: 2 },
    createData(mimeType, text) {
      let currentProp = { shareOption: 2, localOnly: false };
      return {
        mimeType,
        text,
        getProperty() {
          return { ...currentProp };
        },
        setProperty(nextProp) {
          currentProp = { ...nextProp };
        },
        _inspectProperty() {
          return currentProp;
        }
      };
    },
    getSystemPasteboard() {
      return {
        async setData(data) {
          clipboardWrites.push({
            mimeType: data.mimeType,
            text: data.text,
            property: data._inspectProperty()
          });
        }
      };
    }
  };
  return { pasteboard, clipboardWrites, SHARE_LOCAL };
}

test('HMAC-signed notification Wants enforce zero new Want keys, reject forged save Wants, and keep probe compatibility', async () => {
  const notifSource = readRepoFile('entry/src/main/ets/services/TaildropNotificationService.ets');
  const adapterSource = readRepoFile('entry/src/main/ets/services/AppShellIntentAdapter.ets');

  // Verify zero new Want parameter keys in both producer and consumer.
  const expectedWantKeys = [
    'taildropNotificationAction',
    'taildropNotificationEventId',
    'taildropNotificationFileName',
    'taildropNotificationFileSize',
    'taildropNotificationReceivedAtMs',
    'taildropOpenInbox'
  ];
  const paramBlockMatch = notifSource.match(/parameters:\s*\{([\s\S]*?)\}/);
  assert.ok(paramBlockMatch, 'WantAgent parameters block present');
  const producerKeys = [...paramBlockMatch[1].matchAll(/^\s*([A-Za-z0-9_]+)\s*:/gm)]
    .map(m => m[1])
    .sort();
  assert.deepEqual(producerKeys, expectedWantKeys, 'zero new Want keys emitted by TaildropNotificationService');

  const consumerKeys = [...new Set([...adapterSource.matchAll(/want\.parameters\?\.([A-Za-z0-9_]+)/g)].map(m => m[1]))]
    .sort();
  assert.deepEqual(consumerKeys, expectedWantKeys, 'zero new Want keys read by AppShellIntentAdapter');

  // Load real AtomicFileStore + AppShellIntentAdapter + TaildropNotificationService + TaildropReceiveGateway.
  const fsEnv = createDirectoryAwareFileIo();
  const publishedNotifications = [];
  const createdWantAgents = [];
  let randomCalls = 0;
  const fixedSecretBytes = Buffer.from(
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'hex'
  );
  const { pasteboard } = createPasteboardRecorder();

  const ctx = loadEtsModules(
    [
      'services/AtomicFileStore',
      'services/AppShellIntentAdapter',
      'services/TaildropNotificationService',
      'services/TaildropReceiveGateway'
    ],
    {
      fileIo: fsEnv.fileIo,
      pasteboard,
      cryptoFramework: {
        createRandom: () => ({
          generateRandomSync(len) {
            assert.equal(len, 32);
            randomCalls++;
            return { data: new Uint8Array(fixedSecretBytes) };
          }
        })
      },
      wantAgent: {
        OperationType: { START_ABILITY: 1 },
        WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
        async getWantAgent(info) {
          createdWantAgents.push(info);
          return info;
        }
      },
      notificationManager: {
        SlotType: { SERVICE_INFORMATION: 1, SOCIAL_COMMUNICATION: 2 },
        ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
        isNotificationEnabled: async () => true,
        isSupportTemplate: async () => true,
        publish: async req => { publishedNotifications.push(req); },
        cancel: async () => {}
      },
      hilog: { info() {}, warn() {}, error() {} },
      Date,
      Math,
      JSON,
      Number,
      String
    }
  );

  const filesDir = '/data/files';
  const secretFile = `${filesDir}/taildrop-notification-secret-v1.txt`;
  const adapter = new ctx.AppShellIntentAdapter();
  const receiveGateway = new ctx.TaildropReceiveGateway();

  // 1. Before any notification is published, a forged 'save' Want MUST be rejected AND must NOT create a secret file.
  const forgedBeforeSecret = adapter.toFeatureAction({
    parameters: {
      taildropOpenInbox: true,
      taildropNotificationAction: 'save',
      taildropNotificationFileName: 'notes.txt',
      taildropNotificationFileSize: 12,
      taildropNotificationReceivedAtMs: 1795000000123,
      taildropNotificationEventId: '1795000000123:421001:' + 'a'.repeat(64)
    }
  }, filesDir);
  assert.deepEqual(JSON.parse(JSON.stringify(forgedBeforeSecret)), {
    openTaildropInbox: false,
    taildropNotificationAction: ''
  });
  assert.equal(fsEnv.mem.files.has(secretFile), false, 'verification never creates notification secret');

  // 2. Publish a real completion notification for a UTF-8 named text file.
  await ctx.publishTaildropSavePrompt(
    { filesDir, resourceManager: { getStringByNameSync: name => name } },
    '季度报告-notes.txt',
    42,
    1795000000555
  );
  assert.equal(randomCalls, 1, 'secret generated once');
  assert.equal(fsEnv.mem.files.get(secretFile), fixedSecretBytes.toString('hex'));

  // Second publish reuses existing secret without calling RNG again.
  await ctx.publishTaildropSavePrompt(
    { filesDir, resourceManager: { getStringByNameSync: name => name } },
    'second.txt',
    10,
    1795000000999
  );
  assert.equal(randomCalls, 1, 'existing 64-hex secret is reused');

  // Inspect the 3 WantAgents emitted for the first notification (open, save, later).
  const [openAgentInfo, saveAgentInfo, laterAgentInfo] = createdWantAgents.slice(0, 3);
  const openWant = openAgentInfo.wants[0];
  const saveWant = saveAgentInfo.wants[0];
  const laterWant = laterAgentInfo.wants[0];
  assert.equal(saveWant.parameters.taildropNotificationAction, 'save');

  // Cross-check pure-ArkTS HMAC-SHA256 against Node's OpenSSL crypto.createHmac!
  const eventParts = saveWant.parameters.taildropNotificationEventId.split(':');
  assert.equal(eventParts.length, 3);
  const [tsPart, notifIdPart, arktsMac] = eventParts;
  assert.equal(tsPart, '1795000000555');
  const nodeMac = crypto
    .createHmac('sha256', fixedSecretBytes)
    .update(`taildrop-want-v1\nsave\n季度报告-notes.txt\n42\n1795000000555\n${notifIdPart}`, 'utf8')
    .digest('hex');
  assert.equal(arktsMac, nodeMac, 'pure-ArkTS HMAC-SHA256 matches OpenSSL HMAC-SHA256 bit-for-bit');

  // 3. Forged 'save' variants MUST all be rejected with openTaildropInbox: false:
  const forgedSaveCases = [
    // Missing eventId & receivedAtMs (legacy unsigned)
    {
      taildropOpenInbox: true,
      taildropNotificationAction: 'save',
      taildropNotificationFileName: '季度报告-notes.txt',
      taildropNotificationFileSize: 42
    },
    // Legacy receivedAtMs: -1
    {
      taildropOpenInbox: true,
      taildropNotificationAction: 'save',
      taildropNotificationFileName: '季度报告-notes.txt',
      taildropNotificationFileSize: 42,
      taildropNotificationReceivedAtMs: -1,
      taildropNotificationEventId: saveWant.parameters.taildropNotificationEventId
    },
    // Wrong HMAC
    {
      ...saveWant.parameters,
      taildropNotificationEventId: `${tsPart}:${notifIdPart}:${'0'.repeat(64)}`
    },
    // Tampered fileName
    {
      ...saveWant.parameters,
      taildropNotificationFileName: 'other.txt'
    },
    // Tampered size
    {
      ...saveWant.parameters,
      taildropNotificationFileSize: 43
    },
    // Tampered receivedAtMs
    {
      ...saveWant.parameters,
      taildropNotificationReceivedAtMs: 1795000000556
    },
    // Action-swap attack: reuse valid 'open' HMAC token with action='save'!
    {
      ...openWant.parameters,
      taildropNotificationAction: 'save'
    },
    // Action-swap attack: reuse valid 'later' HMAC token with action='save'!
    {
      ...laterWant.parameters,
      taildropNotificationAction: 'save'
    }
  ];
  for (const params of forgedSaveCases) {
    const res = adapter.toFeatureAction({ parameters: params }, filesDir);
    assert.deepEqual(
      JSON.parse(JSON.stringify(res)),
      { openTaildropInbox: false, taildropNotificationAction: '' },
      `forged save Want rejected: ${JSON.stringify(params)}`
    );
  }
  assert.equal(
    receiveGateway.parseNotificationAction(JSON.stringify({
      action: 'save',
      fileName: 'notes.txt',
      size: 42,
      receivedAtMs: -1,
      eventId: saveWant.parameters.taildropNotificationEventId,
      atMs: 100
    })),
    undefined,
    'TaildropReceiveGateway also rejects receivedAtMs <= 0 for save'
  );

  // 4. Valid HMAC-signed 'save' Want succeeds through EntryAbility -> AppShellIntentAdapter -> TaildropReceiveGateway!
  const entrySource = readRepoFile('entry/src/main/ets/entryability/EntryAbility.ets');
  assert.match(
    entrySource,
    /this\.appShellIntentAdapter\.toFeatureAction\(want,\s*this\.context\.filesDir\)/,
    'EntryAbility passes context.filesDir to AppShellIntentAdapter.toFeatureAction'
  );
  const validSave = adapter.toFeatureAction(saveWant, filesDir);
  assert.equal(validSave.openTaildropInbox, true);
  const parsedSave = receiveGateway.parseNotificationAction(validSave.taildropNotificationAction);
  assert.ok(parsedSave, 'TaildropReceiveGateway accepts 88-char signed eventId');
  assert.equal(parsedSave.action, 'save');
  assert.equal(parsedSave.fileName, '季度报告-notes.txt');
  assert.equal(parsedSave.receivedAtMs, 1795000000555);

  // 5. Legacy device-app-shell-probe.ps1 compatibility ('later' without eventId/receivedAtMs + 'delete' rejected).
  const probeLater = adapter.toFeatureAction({
    parameters: {
      taildropOpenInbox: true,
      taildropNotificationAction: 'later',
      taildropNotificationFileName: 'm7-notification.txt',
      taildropNotificationFileSize: 1
    }
  }, filesDir);
  assert.equal(probeLater.openTaildropInbox, true);
  const parsedProbeLater = receiveGateway.parseNotificationAction(probeLater.taildropNotificationAction);
  assert.equal(parsedProbeLater.action, 'later');
  assert.equal(parsedProbeLater.receivedAtMs, -1);

  const probeDelete = adapter.toFeatureAction({
    parameters: {
      taildropOpenInbox: false,
      taildropNotificationAction: 'delete',
      taildropNotificationFileName: 'm7-notification.txt',
      taildropNotificationFileSize: 1
    }
  }, filesDir);
  assert.deepEqual(JSON.parse(JSON.stringify(probeDelete)), {
    openTaildropInbox: false,
    taildropNotificationAction: ''
  });
});

test('BridgeStatus gates Taildrop openInbox and notification actions behind App Lock and resumes on unlock', async () => {
  const bridgeSource = readRepoFile('entry/src/main/ets/components/BridgeStatus.ets');
  const taildropCtrlSource = readRepoFile('entry/src/main/ets/services/TaildropSessionController.ets');
  const gatewayCode = stripEtsModuleSyntax(readEtsSource('services/TaildropReceiveGateway'));
  const methodNames = [
    'requireAppAuthentication',
    'onTaildropOpenInbox',
    'onTaildropNotificationAction',
    'resumeDeferredTaildropShellActions',
    'onAppLockRequiredChanged',
    'loadSecurityPreferences'
  ];
  const classCode = stripTypeScriptTypes(
    `${gatewayCode}\nclass TaildropActionCtrl {\n` +
    extractMethod(taildropCtrlSource, 'onTaildropNotificationAction') +
    `\n}\nclass BridgeLockGateHost {\n` +
    methodNames.map(name => extractMethod(bridgeSource, name)).join('\n') +
    `\n}\nglobalThis.BridgeLockGateHost = BridgeLockGateHost;\nglobalThis.TaildropActionCtrl = TaildropActionCtrl;\nglobalThis.TaildropReceiveGateway = TaildropReceiveGateway;`
  );

  const appStorage = new Map();
  let securityLoadResolve;
  let hostRef = null;
  const sandbox = {
    AppStorage: {
      get: key => appStorage.get(key),
      setOrCreate: (key, value) => {
        appStorage.set(key, value);
        if (hostRef && (key === 'taildropOpenInbox' || key === 'taildropNotificationAction')) {
          hostRef[key] = value;
        }
      }
    },
    AppSecurityPreferences: {
      load: () => new Promise(resolve => { securityLoadResolve = resolve; }),
      isPrivacyProtectionArmedSync: () => true
    },
    Date,
    JSON,
    Number
  };
  vm.runInNewContext(classCode, sandbox);

  const host = new sandbox.BridgeLockGateHost();
  hostRef = host;
  const receiveGateway = new sandbox.TaildropReceiveGateway();
  const savedFromNotification = [];
  const externalTabNavigations = [];
  const lifecycleRetries = [];

  const actionCtrl = new sandbox.TaildropActionCtrl();
  Object.assign(actionCtrl, {
    taildropReceiveGateway: receiveGateway,
    taildropNotificationActionInFlight: undefined,
    taildropNotificationActionRetryScheduled: false,
    saveTaildropFileFromNotification(file) { savedFromNotification.push(file); },
    host: {
      isAppShellReady: () => host.appShellReady,
      isSecurityPreferencesReady: () => host.securityPreferencesReady,
      isAppLockRequired: () => host.appLockRequired,
      getTaildropNotificationAction: () => host.taildropNotificationAction,
      clearTaildropNotificationAction: () => sandbox.AppStorage.setOrCreate('taildropNotificationAction', ''),
      scheduleExternalTabNavigation: tab => externalTabNavigations.push(tab),
      getTaildropWaitingFiles: () => host.taildropWaitingFiles,
      scheduleLifecycleTask: cb => lifecycleRetries.push(cb)
    }
  });

  Object.assign(host, {
    lifecycleGeneration: 1,
    appShellReady: true,
    securityPreferencesReady: false,
    appLockEnabled: false,
    folderLockEnabled: false,
    lockedFolderPaths: [],
    appLockRequired: false,
    appLockAuthenticating: false,
    updateChangelogShowPending: false,
    taildropOpenInbox: 1795000001000,
    taildropNotificationAction: JSON.stringify({
      action: 'save',
      fileName: 'secret-note.txt',
      size: 18,
      receivedAtMs: 1795000002222,
      eventId: '1795000002222:421009:' + 'b'.repeat(64),
      atMs: 1795000002300
    }),
    taildropWaitingFiles: [
      { name: 'secret-note.txt', size: 18, receivedAtMs: 1795000002222 }
    ],
    taildropSessionController: actionCtrl,
    syncWindowPrivacyMode() {},
    promptAppUnlock() {},
    invalidateRemoteStreamLaunch() {},
    stopDeviceDetailRefreshPolling() {},
    scheduleExternalTabNavigation(tab) { externalTabNavigations.push(tab); },
    scheduleLifecycleTask(cb) { lifecycleRetries.push(cb); }
  });

  appStorage.set('taildropOpenInbox', host.taildropOpenInbox);
  appStorage.set('taildropNotificationAction', host.taildropNotificationAction);

  // 1. Cold-start before securityPreferencesReady: BOTH handlers must block without clearing pending actions!
  host.loadSecurityPreferences({ filesDir: '/data/files' });
  host.onTaildropOpenInbox();
  host.onTaildropNotificationAction();
  assert.equal(externalTabNavigations.length, 0);
  assert.equal(savedFromNotification.length, 0);
  assert.equal(appStorage.get('taildropOpenInbox'), 1795000001000, 'openInbox preserved while unready');
  assert.ok(appStorage.get('taildropNotificationAction').length > 0, 'notification action preserved while unready');

  // 2. Security preferences finish loading with App Lock ARMED -> still blocked while appLockRequired === true!
  securityLoadResolve({
    appLockEnabled: true,
    folderLockEnabled: false,
    lockedFolderPaths: []
  });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(host.securityPreferencesReady, true);
  assert.equal(host.appLockRequired, true);
  host.onTaildropOpenInbox();
  host.onTaildropNotificationAction();
  assert.equal(externalTabNavigations.length, 0);
  assert.equal(savedFromNotification.length, 0);

  // 3. User authenticates and unlocks (appLockRequired -> false): deferred actions resume automatically!
  host.appLockRequired = false;
  host.onAppLockRequiredChanged();
  assert.equal(appStorage.get('taildropOpenInbox'), 0, 'taildropOpenInbox consumed so later unlocks do not replay');
  assert.ok(externalTabNavigations.length >= 1, 'deferred Transfer tab navigation executed on unlock');
  assert.equal(savedFromNotification.length, 1, 'deferred save action resumed on unlock');
  assert.equal(savedFromNotification[0].name, 'secret-note.txt');
  assert.equal(appStorage.get('taildropNotificationAction'), '');

  // 4. Subsequent lock/unlock cycle does NOT replay already-consumed openInbox or save action!
  const prevNavCount = externalTabNavigations.length;
  host.appLockRequired = true;
  host.onAppLockRequiredChanged();
  host.appLockRequired = false;
  host.onAppLockRequiredChanged();
  assert.equal(externalTabNavigations.length, prevNavCount);
  assert.equal(savedFromNotification.length, 1);

  // 5. Mismatched receivedAtMs on 'save' does NOT match another waiting file with the same name/size!
  sandbox.AppStorage.setOrCreate('taildropNotificationAction', JSON.stringify({
    action: 'save',
    fileName: 'secret-note.txt',
    size: 18,
    receivedAtMs: 1795000009999,
    eventId: '1795000009999:421010:' + 'c'.repeat(64),
    atMs: 1795000010000
  }));
  host.onTaildropNotificationAction();
  assert.equal(savedFromNotification.length, 1, 'mismatched receivedAtMs never triggers save on another file');
});

test('all 5 clipboard copy sites enforce ShareOption.LOCALDEVICE + localOnly and block while locked', async () => {
  const bridgeSource = readRepoFile('entry/src/main/ets/components/BridgeStatus.ets');
  const taildropCtrlSource = readRepoFile('entry/src/main/ets/services/TaildropSessionController.ets');
  const taildriveSource = readRepoFile('entry/src/main/ets/components/TaildriveBrowser.ets');

  assert.equal(bridgeSource.includes('pasteboard.createData'), false, 'no raw pasteboard.createData in BridgeStatus');
  assert.equal(taildropCtrlSource.includes('pasteboard.createData'), false, 'no raw pasteboard.createData in TaildropSessionController');
  assert.equal(taildriveSource.includes('pasteboard.createData'), false, 'no raw pasteboard.createData in TaildriveBrowser');

  const rec = createPasteboardRecorder();
  const fsEnv = createDirectoryAwareFileIo();
  fsEnv.writeFile('/data/cache/staged.txt', 'staged-taildrop-secret');

  const adapterCode = stripEtsModuleSyntax(readEtsSource('services/AtomicFileStore')) + '\n' +
    stripEtsModuleSyntax(readEtsSource('services/AppShellIntentAdapter'));

  const bridgeMethods = [
    'isSecurityCoverActive',
    'copyPlainText',
    'copyDeviceValue'
  ];
  const taildropClipMethods = [
    'copyTaildropTextToClipboard',
    'copyTaildropTextPreview'
  ];
  const taildriveMethods = [
    'copyEntryPath'
  ];

  const vmSource = stripTypeScriptTypes(
    `${adapterCode}\n` +
    `const TAILDROP_TEXT_CLIPBOARD_MAX_BYTES = 1048576;\n` +
    `class BridgeClipHost {\n${bridgeMethods.map(m => extractMethod(bridgeSource, m)).join('\n')}\n}\n` +
    `class TaildropClipHost {\n${taildropClipMethods.map(m => extractMethod(taildropCtrlSource, m)).join('\n')}\n}\n` +
    `class TaildriveClipHost {\n${taildriveMethods.map(m => extractMethod(taildriveSource, m)).join('\n')}\n}\n` +
    `globalThis.BridgeClipHost = BridgeClipHost;\nglobalThis.TaildropClipHost = TaildropClipHost;\nglobalThis.TaildriveClipHost = TaildriveClipHost;`
  );

  const sandbox = {
    pasteboard: rec.pasteboard,
    fileIo: fsEnv.fileIo,
    cryptoFramework: { createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(32) }) }) },
    $r: k => k,
    Date,
    Promise
  };
  vm.runInNewContext(vmSource, sandbox);

  const b = new sandbox.BridgeClipHost();
  const tdClip = new sandbox.TaildropClipHost();
  let releasedClaims = 0;
  Object.assign(b, {
    securityPreferencesReady: false,
    appLockRequired: true,
    taildropReceivedText: 'inline-preview-secret',
    taildropReceive: {
      requestId: 7,
      action: 'stage',
      state: 'awaiting_text_preview',
      reason: '',
      name: 'note.txt',
      size: 21,
      path: '/data/cache/staged.txt'
    },
    showToast() {},
    taildropState: 'offline'
  });
  Object.assign(tdClip, {
    releaseTaildropNotificationActionClaim() { releasedClaims++; },
    isCurrentTaildropReceive: () => true,
    completeTaildropReceive() {},
    host: {
      isSecurityCoverActive: () => b.isSecurityCoverActive(),
      getTaildropReceive: () => b.taildropReceive,
      setTaildropReceive: r => { b.taildropReceive = r; },
      setTaildropTextPreviewVisible() {},
      getTaildropReceivedText: () => b.taildropReceivedText,
      getTaildropState: () => b.taildropState
    }
  });
  b.copyTaildropTextToClipboard = r => tdClip.copyTaildropTextToClipboard(r);
  b.copyTaildropTextPreview = () => tdClip.copyTaildropTextPreview();

  const td = new sandbox.TaildriveClipHost();
  let folderAccessible = false;
  Object.assign(td, {
    appLockActive: true,
    path: '/tailnet/nas/secret',
    hasFolderAccess: () => folderAccessible,
    toast() {},
    stringValue: (_r, fallback) => fallback
  });

  // 1. While locked, ALL 5 clipboard copy sites must write ZERO entries to system pasteboard!
  b.copyPlainText('hosplayer://link', 'ok');
  b.copyDeviceValue('100.64.0.8', 'ok');
  assert.equal(await b.copyTaildropTextToClipboard({
    requestId: 1, action: 'stage', state: 'staged', reason: '', name: 'a.txt', size: 22, path: '/data/cache/staged.txt'
  }), false);
  b.copyTaildropTextPreview();
  await td.copyEntryPath({ path: '/tailnet/nas/secret/doc.pdf', name: 'doc.pdf', isDir: false, size: 10, modifiedAtMs: 0 });
  await Promise.resolve();
  assert.equal(rec.clipboardWrites.length, 0, 'zero clipboard writes while App Lock or Folder Lock is active');
  assert.equal(releasedClaims, 1, 'blocked copyTaildropTextPreview releases notification claim cleanly');

  // 2. Unlock App Lock and Folder Lock -> all 5 sites write with ShareOption.LOCALDEVICE + localOnly = true!
  b.securityPreferencesReady = true;
  b.appLockRequired = false;
  td.appLockActive = false;
  folderAccessible = true;

  b.copyPlainText('hosplayer://link', 'ok');
  b.copyDeviceValue('100.64.0.8', 'ok');
  assert.equal(await b.copyTaildropTextToClipboard({
    requestId: 1, action: 'stage', state: 'staged', reason: '', name: 'a.txt', size: 22, path: '/data/cache/staged.txt'
  }), true);
  b.copyTaildropTextPreview();
  await td.copyEntryPath({ path: '/tailnet/nas/secret/doc.pdf', name: 'doc.pdf', isDir: false, size: 10, modifiedAtMs: 0 });
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(rec.clipboardWrites.length, 5, 'all 5 clipboard copy sites executed once unlocked');
  assert.deepEqual(
    rec.clipboardWrites.map(w => w.text),
    [
      'hosplayer://link',
      '100.64.0.8',
      'staged-taildrop-secret',
      'inline-preview-secret',
      '/tailnet/nas/secret/doc.pdf'
    ]
  );
  for (const write of rec.clipboardWrites) {
    assert.equal(write.property.shareOption, rec.SHARE_LOCAL, `LOCALDEVICE set for ${write.text}`);
    assert.equal(write.property.localOnly, true, `localOnly=true set for ${write.text}`);
  }
});

test('TaildrivePreviewGateway attributes preview buckets and purges locked + unattributed buckets without following symlinks', async () => {
  const fsEnv = createDirectoryAwareFileIo();
  const ctx = loadEtsModules(
    ['services/AtomicFileStore', 'services/TaildrivePreviewGateway'],
    {
      fileIo: fsEnv.fileIo,
      ControlServerConfig: { load: () => ({ controlURL: 'https://controlplane.tailscale.com' }) },
      AccountProfiles: {
        current: () => ({ activeId: 'default' }),
        cacheRoot: (_filesDir, cacheDir) => cacheDir
      },
      image: {},
      media: {},
      Date,
      Math,
      JSON,
      Number,
      Array
    }
  );

  const gateway = new ctx.TaildrivePreviewGateway();
  const appContext = { filesDir: '/data/files', cacheDir: '/data/cache' };

  const secretEntry = {
    path: '/tailnet/nas/secret/payroll.pdf',
    name: 'payroll.pdf',
    size: 16,
    isDir: false,
    modifiedAtMs: 1
  };
  const nestedSecretEntry = {
    path: '/tailnet/nas/secret/q4/bonus.jpg',
    name: 'bonus.jpg',
    size: 12,
    isDir: false,
    modifiedAtMs: 1
  };
  const publicEntry = {
    path: '/tailnet/nas/public/welcome.jpg',
    name: 'welcome.jpg',
    size: 14,
    isDir: false,
    modifiedAtMs: 1
  };

  const secretPreviewPath = gateway.prepareDownload(appContext, secretEntry);
  const nestedPreviewPath = gateway.prepareDownload(appContext, nestedSecretEntry);
  const publicPreviewPath = gateway.prepareDownload(appContext, publicEntry);

  fsEnv.writeFile(secretPreviewPath, '0123456789abcdef');
  fsEnv.writeFile(`${secretPreviewPath}.thumb.jpg`, 'secret-thumb');
  fsEnv.writeFile(nestedPreviewPath, '0123456789ab');
  fsEnv.writeFile(publicPreviewPath, '0123456789abcd');
  fsEnv.writeFile(`${publicPreviewPath}.thumb.jpg`, 'public-thumb');

  // Legacy un-attributed bucket (no .origin.json) + symlink inside secret bucket pointing outside preview root.
  const previewRoot = gateway.root(appContext);
  const legacyFile = `${previewRoot}/deadbeef/pre-upgrade-secret.pdf`;
  fsEnv.writeFile(legacyFile, 'legacy-plaintext');
  const outsideTarget = '/data/files/must-survive.txt';
  fsEnv.writeFile(outsideTarget, 'important-state');
  const secretBucketDir = secretPreviewPath.slice(0, secretPreviewPath.lastIndexOf('/'));
  fsEnv.addSymlink(`${secretBucketDir}/escape-link`, outsideTarget);

  // Verify .origin.json was written for attributed downloads.
  const secretOrigin = JSON.parse(fsEnv.mem.files.get(`${secretBucketDir}/.origin.json`));
  assert.deepEqual(secretOrigin, {
    schemaVersion: 1,
    remotePath: '/tailnet/nas/secret/payroll.pdf',
    size: 16,
    modifiedAtMs: 1,
    etag: ''
  });
  assert.ok(gateway.cachedPreview(appContext, secretEntry));
  assert.ok(gateway.cachedPreview(appContext, publicEntry));

  // Same-size modifiedAtMs or etag change must invalidate cachedPreview and cachedPreviewAsync.
  assert.equal(
    gateway.cachedPreview(appContext, { ...publicEntry, modifiedAtMs: 2 }),
    undefined,
    'same-size modifiedAtMs change invalidates cachedPreview'
  );
  assert.equal(
    await gateway.cachedPreviewAsync(appContext, { ...publicEntry, modifiedAtMs: 2 }),
    undefined,
    'same-size modifiedAtMs change invalidates cachedPreviewAsync'
  );
  const etagEntryV1 = {
    path: '/tailnet/nas/public/etag-doc.txt',
    name: 'etag-doc.txt',
    size: 8,
    isDir: false,
    modifiedAtMs: 100,
    etag: '"rev-1"'
  };
  const etagPreviewPath = gateway.prepareDownload(appContext, etagEntryV1);
  fsEnv.writeFile(etagPreviewPath, '12345678');
  assert.ok(gateway.cachedPreview(appContext, etagEntryV1));
  assert.equal(
    gateway.cachedPreview(appContext, { ...etagEntryV1, etag: '"rev-2"' }),
    undefined,
    'same-size etag change invalidates cachedPreview'
  );
  assert.equal(
    await gateway.cachedPreviewAsync(appContext, { ...etagEntryV1, etag: '"rev-2"' }),
    undefined,
    'same-size etag change invalidates cachedPreviewAsync'
  );

  // Purge '/tailnet/nas/secret/' -> purges secretEntry, nestedSecretEntry, AND un-attributed legacy bucket,
  // preserves publicEntry + public thumbnail, and never deletes symlink target outside preview root!
  gateway.purgeProtectedPreviews(appContext, [' /tailnet/nas/secret/ ']);

  assert.equal(gateway.cachedPreview(appContext, secretEntry), undefined, 'direct locked file purged');
  assert.equal(gateway.cachedPreview(appContext, nestedSecretEntry), undefined, 'nested locked file purged');
  assert.equal(fsEnv.mem.files.has(`${secretPreviewPath}.thumb.jpg`), false, 'locked thumbnail purged');
  assert.equal(fsEnv.mem.files.has(legacyFile), false, 'un-attributed legacy bucket purged');
  assert.equal(fsEnv.mem.files.get(outsideTarget), 'important-state', 'symlink target outside bucket untouched');

  const survivingPublic = gateway.cachedPreview(appContext, publicEntry);
  assert.ok(survivingPublic, 'unrelated unlocked folder preview preserved');
  assert.equal(survivingPublic.path, publicPreviewPath);
  assert.equal(survivingPublic.thumbnailPath, `${publicPreviewPath}.thumb.jpg`);

  // Verify behavioral eviction + gateway purge in TaildriveSessionController and BridgeStatus.
  const bridgeSource = readRepoFile('entry/src/main/ets/components/BridgeStatus.ets');
  const tdSessionScope = loadEtsModules(['services/TaildriveSessionController']);
  const purgedTargets = [];
  let thumbnails = [
    { remotePath: '/tailnet/nas/secret/payroll.pdf', uri: 'file://1' },
    { remotePath: '/tailnet/nas/public/welcome.jpg', uri: 'file://2' }
  ];
  let cachedEntries = [secretEntry, publicEntry];
  const tdController = new tdSessionScope.TaildriveSessionController({
    getCachedEntries: () => cachedEntries,
    setCachedEntries: next => { cachedEntries = next; },
    filterProtectedThumbnails: matchesProtected => {
      thumbnails = thumbnails.filter(item => !matchesProtected(item.remotePath));
    },
    purgeGatewayPreviewCaches: targets => {
      purgedTargets.push(targets);
    }
  });
  tdController.purgeProtectedPreviewCaches(['/tailnet/nas/secret/']);
  assert.deepEqual(JSON.parse(JSON.stringify(purgedTargets)), [['/tailnet/nas/secret']]);
  assert.deepEqual(thumbnails.map(t => t.remotePath), ['/tailnet/nas/public/welcome.jpg']);
  assert.deepEqual(cachedEntries.map(e => e.path), ['/tailnet/nas/public/welcome.jpg']);
  assert.match(bridgeSource, /new TaildrivePreviewGateway\(\)\.purgeProtectedPreviews\(context,\s*lockedPaths\)/);
});

test('BuildProfile.DEBUG gates crash simulation across AccountDiagnosticsGateway and BridgeStatus', async () => {
  const bridgeSource = readRepoFile('entry/src/main/ets/components/BridgeStatus.ets');
  const panelCode = extractMethod(bridgeSource, 'DiagnosticsDangerousPanel');
  assert.match(
    panelCode,
    /if\s*\(\s*BuildProfile\.DEBUG\s*\)\s*\{\s*this\.StandardActionButton\([\s\S]*?'diagnostic-simulate-crash'/,
    'diagnostic-simulate-crash button is gated by if (BuildProfile.DEBUG)'
  );

  for (const debugFlag of [false, true]) {
    const fsEnv = createDirectoryAwareFileIo();
    let aborted = 0;
    const timers = [];
    const gatewayCtx = loadEtsModules(
      ['services/AccountDiagnosticsGateway'],
      {
        BuildProfile: { DEBUG: debugFlag },
        appProcess: { abort() { aborted++; } },
        fileIo: fsEnv.fileIo,
        nativeBridge: {},
        DiagnosticEventStore: { record() {} },
        DiagnosticReportService: {},
        HomeReadOnlyGateway: class {},
        DiagnosticPrivacy: { formatNativeFailure: (_t, e) => String(e) },
        setTimeout: (fn, delay) => { timers.push({ fn, delay }); return timers.length; }
      }
    );

    const gateway = new gatewayCtx.AccountDiagnosticsGateway();
    const staged = gateway.stageCrashProbeStatus({ filesDir: '/data/files' }, 'FAKE_CRASH');
    gateway.abortProcessAfter(120);

    if (!debugFlag) {
      assert.equal(staged, false, 'stageCrashProbeStatus returns false in Release');
      assert.equal(fsEnv.mem.files.has('/data/files/vpn-probe-status.txt'), false);
      assert.equal(timers.length, 0, 'abortProcessAfter is a no-op in Release');
    } else {
      assert.equal(staged, true, 'stageCrashProbeStatus succeeds in Debug');
      assert.equal(fsEnv.mem.files.get('/data/files/vpn-probe-status.txt'), 'FAKE_CRASH');
      assert.equal(timers.length, 1);
      timers[0].fn();
      assert.equal(aborted, 1);
    }

    // Also test BridgeStatus.confirmSimulateAppCrash and simulateAppCrash under both DEBUG flags.
    const dialogs = [];
    let vpnStopped = 0;
    const bridgeCrashCode = stripTypeScriptTypes(
      `class CrashHost {\n` +
      extractMethod(bridgeSource, 'confirmSimulateAppCrash') + '\n' +
      extractMethod(bridgeSource, 'simulateAppCrash') + '\n' +
      `}\nglobalThis.CrashHost = CrashHost;`
    );
    const crashSandbox = {
      BuildProfile: { DEBUG: debugFlag },
      $r: k => ({ id: k }),
      Date
    };
    vm.runInNewContext(bridgeCrashCode, crashSandbox);
    const host = new crashSandbox.CrashHost();
    Object.assign(host, {
      diagnosticActionInProgress: false,
      diagnosticActionStatus: '',
      diagnosticActionRequestGuard: { begin: () => 1, isCurrent: () => true },
      accountDiagnosticsGateway: gateway,
      vpnSessionController: {
        async stopVpnExtensionDirect() { vpnStopped++; },
        stopConnectionPolling() {},
        clearConnectionCompletionTimer() {}
      },
      cancelVpnAutoRecovery() {},
      recordDiagnosticEvent() {},
      getUIContext: () => ({
        showAlertDialog: cfg => dialogs.push(cfg),
        getHostContext: () => ({
          filesDir: '/data/files',
          resourceManager: { getStringSync: id => String(id) }
        })
      })
    });

    host.confirmSimulateAppCrash();
    await host.simulateAppCrash();
    if (!debugFlag) {
      assert.equal(dialogs.length, 0, 'confirmSimulateAppCrash blocked in Release');
      assert.equal(vpnStopped, 0, 'simulateAppCrash blocked in Release');
    } else {
      assert.equal(dialogs.length, 1, 'confirmSimulateAppCrash opens dialog in Debug');
      assert.equal(vpnStopped, 1, 'simulateAppCrash runs in Debug');
    }
  }
});

test('Unicode BiDi RLO extension-spoofing and C0/C1 control characters are stripped or rejected across all boundaries', async () => {
  const fsEnv = createDirectoryAwareFileIo();
  const { pasteboard } = createPasteboardRecorder();
  const publishedNotifications = [];
  const createdWantAgents = [];

  const ctx = loadEtsModules(
    [
      'services/AtomicFileStore',
      'services/AppShellIntentAdapter',
      'services/TaildropNotificationService',
      'services/TaildropReceiveGateway',
      'services/TaildrivePreviewGateway'
    ],
    {
      fileIo: fsEnv.fileIo,
      pasteboard,
      cryptoFramework: {
        createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(32).fill(7) }) })
      },
      wantAgent: {
        OperationType: { START_ABILITY: 1 },
        WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
        async getWantAgent(info) { createdWantAgents.push(info); return info; }
      },
      notificationManager: {
        SlotType: { SERVICE_INFORMATION: 1, SOCIAL_COMMUNICATION: 2 },
        ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
        isNotificationEnabled: async () => true,
        isSupportTemplate: async () => true,
        publish: async req => { publishedNotifications.push(req); },
        cancel: async () => {}
      },
      ControlServerConfig: { load: () => ({ controlURL: 'https://controlplane.tailscale.com' }) },
      AccountProfiles: { current: () => ({ activeId: 'default' }), cacheRoot: (_f, c) => c },
      image: {},
      media: {},
      hilog: { info() {}, warn() {}, error() {} },
      Date,
      Math,
      JSON,
      Number,
      String,
      Array
    }
  );

  // Spoofed filename: "invoice\u202Efdp.scr" visually renders as "invoicescr.pdf" without stripping!
  const spoofedName = 'invoice\u202Efdp.scr';
  const controlName = 'report\u0007\u0085\u2066final\u2069.txt';

  // 1. Notification display labels strip RLO & controls, AND tainted file downgrades 'save' button to 'open'.
  await ctx.publishTaildropProgress(
    { filesDir: '/data/files', resourceManager: { getStringByNameSync: n => n } },
    { name: spoofedName, declaredSize: 100, received: 50, startedAtMs: 1 }
  );
  assert.equal(publishedNotifications[0].content.normal.text, 'invoicefdp.scr');
  assert.equal(publishedNotifications[0].template.data.fileName, 'invoicefdp.scr');

  await ctx.publishTaildropSavePrompt(
    { filesDir: '/data/files', resourceManager: { getStringByNameSync: n => n } },
    spoofedName,
    100,
    1795000003333
  );
  assert.equal(publishedNotifications[1].content.normal.text, 'invoicefdp.scr');
  const saveButtonWant = createdWantAgents[1].wants[0];
  assert.equal(saveButtonWant.parameters.taildropNotificationAction, 'open', 'BiDi-tainted file never gets direct save');

  // 2. AppShellIntentAdapter & TaildropReceiveGateway strictly reject BiDi/control-tainted Wants.
  const adapter = new ctx.AppShellIntentAdapter();
  const receiveGateway = new ctx.TaildropReceiveGateway();
  for (const bad of [spoofedName, controlName, 'bad\u200Ename.txt', 'bad\u061Cname.txt']) {
    const res = adapter.toFeatureAction({
      parameters: {
        taildropOpenInbox: true,
        taildropNotificationAction: 'later',
        taildropNotificationFileName: bad,
        taildropNotificationFileSize: 10
      }
    }, '/data/files');
    assert.deepEqual(JSON.parse(JSON.stringify(res)), {
      openTaildropInbox: false,
      taildropNotificationAction: ''
    });
    assert.equal(
      receiveGateway.parseNotificationAction(JSON.stringify({
        action: 'later',
        fileName: bad,
        size: 10,
        receivedAtMs: 100,
        eventId: '100:1',
        atMs: 100
      })),
      undefined
    );
  }

  // 3. TaildrivePreviewGateway.safeName strips BiDi & C0/C1 controls without corrupting extension.
  const previewGateway = new ctx.TaildrivePreviewGateway();
  const safePath = previewGateway.prepareDownload(
    { filesDir: '/data/files', cacheDir: '/data/cache' },
    { path: `/tailnet/share/${spoofedName}`, name: spoofedName, size: 10, isDir: false, modifiedAtMs: 1 }
  );
  assert.ok(safePath.endsWith('/invoicefdp.scr'), `expected stripped safeName, got ${safePath}`);

  // 4. TaildropSessionController, PeerIntegrationController & TaildriveSessionController filename/display sanitizers strip BiDi & C0/C1 controls cleanly.
  const sanitizeScope = loadEtsModules([
    'services/AtomicFileStore',
    'services/AppShellIntentAdapter',
    'services/RecoverableCachePaths',
    'services/TaildropContentGateway',
    'services/TaildropReceiveGateway',
    'services/TaildropSendGateway',
    'services/TaildropSessionController',
    'services/TaildriveSessionController'
  ], {
    fileIo: fsEnv.fileIo,
    pasteboard,
    nativeBridge: {},
    picker: {},
    fileUri: {},
    image: {},
    media: {},
    photoAccessHelper: {},
    cryptoFramework: {
      createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(32).fill(7) }) })
    }
  });
  const peerCtrlRaw = readRepoFile('entry/src/main/ets/services/PeerIntegrationController.ets');
  const formatPeerFn = peerCtrlRaw.match(/export function formatPeerDisplayName[\s\S]*?^\}/m)?.[0];
  assert.ok(formatPeerFn, 'formatPeerDisplayName');
  vm.runInContext(
    `${stripTypeScriptTypes(formatPeerFn.replace(/^export /, ''))}\nglobalThis.formatPeerDisplayName = formatPeerDisplayName;`,
    sanitizeScope
  );
  const td = new sanitizeScope.TaildriveSessionController({});

  assert.equal(sanitizeScope.sanitizeTaildropFileName(spoofedName, 0), 'invoicefdp.scr');
  assert.equal(sanitizeScope.sanitizeTaildropFileName('\u202E\u0007', 2), 'file-3');
  assert.equal(sanitizeScope.formatPeerDisplayName('laptop\u202Eevil.tailnet.ts.net'), 'laptopevil');
  assert.equal(
    sanitizeScope.formatTaildropRecordTitle({ fileName: spoofedName, targetName: 'peer\u202E1', fileCount: 1, direction: 'receive' }),
    'invoicefdp.scr'
  );
  assert.equal(td.validName(spoofedName), false, 'TaildriveSessionController.validName rejects BiDi overrides');
  assert.equal(td.validName(controlName), false, 'TaildriveSessionController.validName rejects C0/C1/isolate controls');
  assert.equal(td.safeLocalName(spoofedName), 'invoicefdp.scr');
  assert.equal(td.sanitizeDisplayLabel(controlName), 'reportfinal.txt');
});
