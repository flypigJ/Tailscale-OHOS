import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource
} from './helpers/ets-vm-loader.mjs';

const REPO_ROOT = new URL('../', import.meta.url);
const readRepoFile = (relPath) => readFileSync(new URL(relPath, REPO_ROOT), 'utf8');

test('SecretStore.ets is deleted, @tailscale/common stays 100% framework-free, and duplicate DTOs/IPC constants/icon switches are eliminated', () => {
  assert.equal(
    existsSync(new URL('entry/src/main/ets/services/SecretStore.ets', REPO_ROOT)),
    false,
    'unused SecretStore.ets stub must be deleted'
  );

  const commonDir = new URL('common/src/main/ets/contracts/', REPO_ROOT);
  const contractFiles = readdirSync(commonDir).filter((name) => name.endsWith('.ets'));
  for (const expected of [
    'ConnectionPathContract.ets',
    'PeerContracts.ets',
    'VpnIpcContracts.ets',
    'TaildropContracts.ets',
    'TaildriveContracts.ets',
    'FileKindCatalog.ets',
    'RequestGuard.ets'
  ]) {
    assert.ok(contractFiles.includes(expected), `expected ${expected} in common/src/main/ets/contracts/`);
  }

  for (const relPath of ['common/src/main/ets/Index.ets', ...contractFiles.map((f) => `common/src/main/ets/contracts/${f}`)]) {
    const src = readRepoFile(relPath);
    assert.doesNotMatch(src, /@kit\.|libtailscale_ohos\.so|\$r\(/, `${relPath} must remain 100% framework-free`);
  }

  const bridgeSrc = readEtsSource('components/BridgeStatus');
  const browserSrc = readEtsSource('components/TaildriveBrowser');
  const vpnSrc = readEtsSource('vpnextensionability/TailscaleVpnExtensionAbility');

  assert.match(bridgeSrc, /from\s+['"]@tailscale\/common['"]/);
  assert.match(browserSrc, /from\s+['"]@tailscale\/common['"]/);
  assert.match(vpnSrc, /from\s+['"]@tailscale\/common['"]/);

  // Neither BridgeStatus nor TaildriveBrowser nor TailscaleVpnExtensionAbility redefines shared DTOs or IPC file constants locally.
  for (const src of [bridgeSrc, vpnSrc]) {
    assert.doesNotMatch(src, /^interface\s+(?:PeerSummary|LocalSendStatus|AccountSummary|MeshArcReceiverStatus|PersistedPeerSnapshot|TaildropTargetSummary|TaildropSnapshot|TaildropTransferSummary|TaildropSendRequest|VpnStopRequest|VpnBackendHandoffRequest)\b/m);
    assert.doesNotMatch(src, /^const\s+(?:VPN_PEERS_FILE_NAME|VPN_STOP_REQUEST_FILE_NAME|VPN_CONNECT_CONFIG_FILE_NAME|TAILDROP_TARGETS_FILE_NAME|TAILDROP_SEND_REQUEST_FILE_NAME)\b/m);
  }
  assert.doesNotMatch(bridgeSrc, /app\.media\.ic_light_7z/, 'BridgeStatus must delegate file icons to FileIconResolver');
  assert.doesNotMatch(browserSrc, /app\.media\.ic_light_7z/, 'TaildriveBrowser must delegate file icons to FileIconResolver');
});

test('FileKindCatalog & FileIconResolver classify .ts/.env/.sql/.json5 as text (never video) and map all 46 FileIconKeys cleanly', () => {
  const sandbox = {
    $r: (resKey) => resKey
  };
  loadEtsModules(['@tailscale/common', 'services/FileIconResolver'], sandbox);

  const {
    IMAGE_FILE_EXTENSIONS,
    PREVIEW_IMAGE_FILE_EXTENSIONS,
    VIDEO_FILE_EXTENSIONS,
    TEXT_FILE_EXTENSIONS,
    TAILDROP_TEXT_MAX_CLIPBOARD_BYTES,
    extractFileExtension,
    classifyFileContentKind,
    isMediaFileName,
    isImageEntry,
    isVideoEntry,
    resolveFileIconKey,
    resolveFileIconTone,
    resolveFileIconResource,
    resolveFileIconColorResource
  } = sandbox;

  // Critical fix: .ts is TypeScript source, NEVER video!
  assert.equal(VIDEO_FILE_EXTENSIONS.includes('ts'), false, '.ts must NOT appear in VIDEO_FILE_EXTENSIONS');
  assert.equal(TEXT_FILE_EXTENSIONS.includes('ts'), true, '.ts must appear in TEXT_FILE_EXTENSIONS');
  assert.equal(isMediaFileName('app.ts'), false);
  assert.equal(isVideoEntry('app.ts'), false);
  assert.equal(classifyFileContentKind('app.ts', 512), 'text');
  assert.equal(resolveFileIconKey('app.ts'), 'text');

  // Dotfiles and modern config/code extensions
  assert.equal(extractFileExtension('.env'), 'env');
  assert.equal(extractFileExtension('/etc/app/.env'), 'env');
  assert.equal(extractFileExtension('trailing.'), '');
  assert.equal(extractFileExtension('README'), '');
  assert.equal(extractFileExtension('..'), '');

  for (const textFile of [
    '.env', 'production.env', 'schema.sql', 'app.json5', 'events.jsonl',
    'Cargo.toml', 'App.swift', 'View.tsx', 'Card.jsx', 'Index.ets', 'index.ts', 'cli.mjs'.replace('.mjs', '.js')
  ]) {
    assert.equal(classifyFileContentKind(textFile, 1024), 'text', `${textFile} should classify as text`);
    assert.equal(isMediaFileName(textFile), false, `${textFile} must not be treated as media`);
  }

  // Size limit enforcement for clipboard text classification
  assert.equal(classifyFileContentKind('notes.md', TAILDROP_TEXT_MAX_CLIPBOARD_BYTES), 'text');
  assert.equal(classifyFileContentKind('notes.md', TAILDROP_TEXT_MAX_CLIPBOARD_BYTES + 1), 'file');
  assert.equal(classifyFileContentKind('notes.md', -1), 'file');

  // Image vs preview image (svg) vs video
  assert.equal(IMAGE_FILE_EXTENSIONS.includes('svg'), false);
  assert.equal(PREVIEW_IMAGE_FILE_EXTENSIONS.includes('svg'), true);
  assert.equal(isImageEntry('vector.svg'), true);
  assert.equal(isImageEntry('raw-blob', 'image/webp'), true);
  assert.equal(isVideoEntry('movie.mkv'), true);
  assert.equal(isVideoEntry('stream-blob', 'video/mp4'), true);
  assert.equal(classifyFileContentKind('photo.heic', 4096), 'image');
  assert.equal(classifyFileContentKind('clip.webm', 4096), 'video');

  // Exhaustive check across all 46 FileIconKey values + FileIconResolver resource keys
  const expectedIconSamples = [
    ['archive.7z', '7z'],
    ['voice.amr', 'amr'],
    ['lossless.ape', 'ape'],
    ['bundle.app', 'app'],
    ['paper.caj', 'caj'],
    ['invite.ics', 'calendar'],
    ['help.chm', 'chm'],
    ['profile.connection', 'connect'],
    ['video.crdownload', 'download'],
    ['plan.dwg', 'dwg'],
    ['cad.dxf', 'dxf'],
    ['diagram.eddx', 'eddx'],
    ['mail.eml', 'eml'],
    ['mindmap.emmx', 'emmx'],
    ['sheet.xlsx', 'excel'],
    ['table.csv', 'excel'],
    ['installer.msi', 'exe'],
    ['track.flac', 'flac'],
    ['pkg.tar.gz', 'gz'],
    ['harmony.hdoc', 'hdoc'],
    ['memo.hinote', 'hinote'],
    ['legacy.htm', 'htm'],
    ['index.html', 'html'],
    ['thesis.kdh', 'kdh'],
    ['debug.log', 'log'],
    ['podcast.m4a', 'm4a'],
    ['song.mp3', 'mp3'],
    ['audio.opus', 'music'],
    ['book.nh', 'nh'],
    ['unknown.xyz123', 'other'],
    ['client.hap', 'other_app'],
    ['manual.pdf', 'pdf'],
    ['photo.png', 'picture'],
    ['deck.pptx', 'ppt'],
    ['compressed.rar', 'rar'],
    ['backup.tar', 'tar'],
    ['ebook.teb', 'teb'],
    ['module.ets', 'text'],
    ['readme.txt', 'txt'],
    ['Makefile', 'unknow'],
    ['movie.mp4', 'video'],
    ['sample.wav', 'wav'],
    ['legacy.wma', 'wma'],
    ['report.docx', 'word'],
    ['pom.xml', 'xml'],
    ['bundle.zip', 'zip'],
    ['image.dmg', 'zip_1']
  ];

  const seenKeys = new Set();
  for (const [fileName, expectedKey] of expectedIconSamples) {
    assert.equal(resolveFileIconKey(fileName), expectedKey, `icon key mismatch for ${fileName}`);
    assert.equal(resolveFileIconResource(fileName), `app.media.ic_light_${expectedKey}`);
    seenKeys.add(expectedKey);
  }
  assert.equal(seenKeys.size, 46, 'all 46 FileIconKey variants must be covered');

  assert.equal(resolveFileIconTone('manual.pdf'), 'red');
  assert.equal(resolveFileIconColorResource('manual.pdf'), 'app.color.transfer_file_icon_red');
  assert.equal(resolveFileIconTone('bundle.zip'), 'yellow');
  assert.equal(resolveFileIconColorResource('bundle.zip'), 'app.color.transfer_file_icon_yellow');
  assert.equal(resolveFileIconTone('release.hap'), 'neutral');
  assert.equal(resolveFileIconColorResource('release.hap'), 'app.color.transfer_file_icon_neutral');
  assert.equal(resolveFileIconTone('index.ts'), 'blue');
  assert.equal(resolveFileIconColorResource('index.ts'), 'app.color.transfer_file_icon_blue');
});

test('RequestGuard (exclusive latest-wins) and EpochRequestGuard (shared read epoch) preserve exact generation invariants and backward-compatible aliases', () => {
  const sandbox = {};
  loadEtsModules([
    'services/AccountDiagnosticsGateway',
    'services/SettingsPreferencesGateway',
    'services/HomeReadOnlyGateway'
  ], sandbox);

  assert.equal(sandbox.AccountDiagnosticsRequestGuard, sandbox.RequestGuard);
  assert.equal(sandbox.SettingsRequestGuard, sandbox.RequestGuard);
  assert.equal(sandbox.HomeReadOnlyRequestGuard, sandbox.EpochRequestGuard);

  // Exclusive RequestGuard: each begin() supersedes previous in-flight work, and 0 is never current.
  const exclusive = new sandbox.RequestGuard();
  assert.equal(exclusive.isCurrent(0), false);
  const first = exclusive.begin();
  assert.equal(first, 1);
  assert.equal(exclusive.isCurrent(first), true);

  const second = exclusive.begin();
  assert.equal(second, 2);
  assert.equal(exclusive.isCurrent(first), false, 'newer exclusive request must invalidate older generation');
  assert.equal(exclusive.isCurrent(second), true);

  exclusive.invalidate();
  assert.equal(exclusive.isCurrent(second), false);

  // Shared EpochRequestGuard: concurrent read-only queries share the current epoch until invalidate().
  const shared = new sandbox.EpochRequestGuard();
  const readA = shared.begin();
  const readB = shared.begin();
  assert.equal(readA, 0);
  assert.equal(readB, 0);
  assert.equal(shared.isCurrent(readA), true);
  assert.equal(shared.isCurrent(readB), true, 'concurrent reads must remain valid in the same epoch');

  shared.invalidate();
  assert.equal(shared.isCurrent(readA), false);
  assert.equal(shared.isCurrent(readB), false);

  const readC = shared.begin();
  assert.equal(readC, 1);
  assert.equal(shared.isCurrent(readC), true);
});

test('TaildropNotificationService publishes Copy/save action (never Open media fallback) for index.ts, .env, schema.sql, and app.json5', async () => {
  const mem = createMemoryFileIo();
  const published = [];
  const sandbox = {
    Math,
    Date: { now: () => 1_796_500_000_000 },
    fileIo: mem.fileIo,
    cryptoFramework: {
      createRandom: () => ({
        generateRandomSync: (len) => ({ data: new Uint8Array(len).fill(0x5a) })
      })
    },
    hilog: { info() {}, warn() {}, error() {} },
    wantAgent: {
      OperationType: { START_ABILITY: 1 },
      WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async (info) => info
    },
    notificationManager: {
      SlotType: { SERVICE_INFORMATION: 1, SOCIAL_COMMUNICATION: 2 },
      ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
      isNotificationEnabled: async () => true,
      isSupportTemplate: async () => false,
      publish: async (request) => { published.push(request); },
      cancel: async () => {}
    }
  };

  loadEtsModules([
    'services/AtomicFileStore',
    'services/AppShellIntentAdapter',
    'services/TaildropNotificationService'
  ], sandbox);

  const strings = {
    notification_taildrop_open_action: 'Open',
    notification_taildrop_copy_action: 'Copy',
    notification_taildrop_save_action: 'Save',
    notification_taildrop_later_action: 'Later',
    notification_taildrop_received_title: 'File received',
    notification_taildrop_received_message: 'Choose how to save the file'
  };
  const context = {
    filesDir: '/files',
    resourceManager: {
      getStringByNameSync: (key) => {
        if (!(key in strings)) {
          throw new Error(`missing key ${key}`);
        }
        return strings[key];
      }
    }
  };

  for (const fileName of ['index.ts', '.env', 'schema.sql', 'app.json5']) {
    published.length = 0;
    await sandbox.publishTaildropSavePrompt(context, fileName, 256, 1_796_500_000_000);
    assert.equal(published.length, 1, `expected notification for ${fileName}`);
    const [laterBtn, primaryBtn] = published[0].actionButtons;
    assert.equal(laterBtn.title, 'Later');
    assert.equal(primaryBtn.title, 'Copy', `${fileName} must offer Copy action instead of Open/Save`);
    assert.equal(
      primaryBtn.wantAgent.wants[0].parameters.taildropNotificationAction,
      'save',
      `${fileName} must dispatch 'save' Want action rather than media 'open' fallback`
    );
  }

  // Real video/image files still use 'Open' + 'open' fallback
  published.length = 0;
  await sandbox.publishTaildropSavePrompt(context, 'clip.mp4', 4096, 1_796_500_000_000);
  assert.equal(published[0].actionButtons[1].title, 'Open');
  assert.equal(published[0].actionButtons[1].wantAgent.wants[0].parameters.taildropNotificationAction, 'open');

  // Binary non-media files use 'Save' + 'save'
  published.length = 0;
  await sandbox.publishTaildropSavePrompt(context, 'bundle.zip', 4096, 1_796_500_000_000);
  assert.equal(published[0].actionButtons[1].title, 'Save');
  assert.equal(published[0].actionButtons[1].wantAgent.wants[0].parameters.taildropNotificationAction, 'save');
});
