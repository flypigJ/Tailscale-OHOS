import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const read = file => readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const guide = read('entry/src/main/ets/components/FeatureSetupGuide.ets');
const shell = read('entry/src/main/ets/components/BridgeStatus.ets');
const files = read('entry/src/main/ets/components/TaildriveBrowser.ets');
const device = read('entry/src/main/ets/components/DeviceDetailSheet.ets');
const rulesSource = read('entry/src/main/ets/services/FeatureGuideEntryRules.ets');
const ruleSandbox = {};
vm.runInNewContext(stripTypeScriptTypes(rulesSource.replace(/export /g, '')), ruleSandbox);
const { transferGuideNotice, taildriveGuideNotice } = ruleSandbox;
const catalogSource = read('entry/src/main/ets/services/FeatureGuideCatalog.ets');
const sandbox = { $r: name => name };
vm.runInNewContext(stripTypeScriptTypes(catalogSource.replace(/export /g, '')) +
  '\nglobalThis.sections = FEATURE_GUIDE_SECTIONS; globalThis.policy = TAILDRIVE_READ_ONLY_POLICY;', sandbox);
const ids = ['connect', 'taildrop', 'taildrive', 'localsend', 'exit', 'subnet', 'media', 'streaming', 'security', 'appearance'];
const locales = ['base', 'zh_CN'].map(locale =>
  JSON.parse(read('entry/src/main/resources/' + locale + '/element/string.json')).string);

test('offline catalog covers feature families with unique stable ids', () => {
  assert.deepEqual(Array.from(sandbox.sections, section => section.id), ids);
  assert.equal(new Set(sandbox.sections.map(section => section.id)).size, ids.length);
  assert.doesNotMatch(catalogSource + guide, /startAbility|http\.request|child_process|preferences|getPreferences/);
});

test('guide references resolve in English and Chinese without duplicate keys', () => {
  const resources = new Set((catalogSource + guide + shell + files + device).match(/app\.string\.feature_guide_[a-z_]+/g));
  for (const strings of locales) {
    const keys = strings.filter(item => item.name.startsWith('feature_guide_')).map(item => item.name);
    assert.equal(keys.length, new Set(keys).size);
    for (const ref of resources) {
      const value = strings.find(item => 'app.string.' + item.name === ref)?.value;
      assert.ok(value?.trim().length, ref);
    }
    for (const id of ids) {
      const body = strings.find(item => item.name === 'feature_guide_' + id + '_body').value;
      assert.match(body, /1\./, id);
      assert.ok(body.split('\n').length >= 4, id);
    }
  }
});

test('Taildrive example is read-only for one user, one share and their own devices', () => {
  const policy = JSON.parse(sandbox.policy);
  assert.deepEqual(policy.nodeAttrs, [{ target: ['you@example.com'], attr: ['drive:share', 'drive:access'] }]);
  assert.deepEqual(policy.grants, [{ src: ['you@example.com'], dst: ['autogroup:self'],
    app: { 'tailscale.com/cap/drive': [{ shares: ['docs'], access: 'ro' }] } }]);
  assert.doesNotMatch(sandbox.policy, /"\*"|"rw"/);
  const taildrive = sandbox.sections.find(section => section.id === 'taildrive');
  assert.ok(taildrive.commands.includes('tailscale drive share docs "C:\\Users\\YourName\\Documents\\Shared"'));
  assert.ok(taildrive.commands.includes('tailscale drive list'));
});

test('policy tutorial explains merging, identity replacement and unsupported shortcuts', () => {
  const en = locales[0].find(item => item.name === 'feature_guide_taildrive_body').value;
  const zh = locales[1].find(item => item.name === 'feature_guide_taildrive_body').value;
  assert.match(en, /Preserve your existing policy/);
  assert.match(en, /duplicate top-level keys/);
  assert.match(en, /Tagged NAS/);
  assert.match(zh, /不要整份替换/);
  assert.match(zh, /换成后台自己的登录身份/);
  assert.match(zh, /不是在手机或后台执行/);
  assert.match(zh, /只读示例下上传、删除/);
});

test('full guide is in Settings help, not About, and retains back navigation', () => {
  const home = shell.slice(shell.indexOf('  private SettingsContent()'), shell.indexOf('  private SettingsAccountDetailContent()'));
  const about = shell.slice(shell.indexOf('  private SettingsAboutDetailContent()'), shell.indexOf('  private SettingsDetailPageMap('));
  assert.match(home, /feature_guide_help_section/);
  assert.match(home, /settings-feature-guide-entry/);
  assert.match(home, /openSettingsDetail\('feature-guide'\)/);
  assert.doesNotMatch(about, /settings-feature-guide-entry/);
  const route = shell.slice(shell.indexOf("} else if (name === 'feature-guide')"), shell.indexOf("} else if (name === 'about')"));
  assert.match(route, /FeatureSetupGuide\(\{\s*contentScroller: this\.featureGuideScroller/);
  assert.match(route, /hideBackButton\(false\)/);
});

test('examples are selectable and guide content is not truncated', () => {
  assert.match(guide, /copyOption\(CopyOptions.LocalDevice\)/);
  assert.match(guide, /textSelectable\(TextSelectableMode.SELECTABLE_FOCUSABLE\)/);
  assert.match(guide, /ForEach\(this.visibleSections\(\)/);
  assert.match(guide, /expandedSection === section.id/);
  assert.doesNotMatch(guide, /maxLines|TextOverflow.Ellipsis/);
});

test('README and getting-started link to both tutorials and limits remain honest', () => {
  for (const file of ['README.md', 'docs/getting-started.md']) {
    const doc = read(file);
    assert.ok(doc.includes('feature-setup.md'));
    assert.ok(doc.includes('feature-setup.zh-CN.md'));
  }
  for (const file of ['docs/feature-setup.md', 'docs/feature-setup.zh-CN.md']) {
    const doc = read(file);
    for (const section of sandbox.sections) {
      assert.ok(doc.includes(JSON.parse(JSON.stringify(locales[file.includes('zh-CN') ? 1 : 0])).find(item => 'app.string.' + item.name === section.title).value));
    }
    assert.ok(doc.includes(sandbox.policy));
    assert.ok(doc.includes('tailscale.com/kb/1369/taildrive'));
  }
  const streamingHelp = locales[0].find(item => item.name === 'feature_guide_streaming_body').value;
  assert.match(streamingHelp, /requires a MoonlightOH build supporting the MeshArc launch contract/);
  assert.match(streamingHelp, /older builds, copy the host address and add it manually/);
  assert.match(locales[0].find(item => item.name === 'feature_guide_connect_body').value, /Use MagicDNS switch is on by default/);
  assert.equal(locales[0].find(item => item.name === 'setting_tailnet_dns').value, 'Use MagicDNS');
  assert.equal(locales[1].find(item => item.name === 'setting_tailnet_dns').value, '使用 MagicDNS');
});

const transfer = overrides => ({ connected: true, refreshing: false, state: 'ready', taildropTargets: 1, busy: false, ...overrides });
const drive = overrides => ({ connected: true, loading: false, busy: false, locked: false, reason: '', listFailure: false,
  path: '/tailnet/device', listedPath: '/tailnet/device', entryCount: 0, search: '', ...overrides });

test('Taildrop distinguish disabled, no targets, disconnected and query failure', () => {
  assert.equal(transferGuideNotice(transfer({ state: 'disabled' })), 'disabled');
  assert.equal(transferGuideNotice(transfer({ taildropTargets: 0 })), 'targets');
  assert.equal(transferGuideNotice(transfer({ connected: false, state: 'disabled' })), 'connect');
  assert.equal(transferGuideNotice(transfer({ state: 'unavailable' })), 'error');
  assert.equal(transferGuideNotice(transfer({ state: 'ready' })), '');
});

test('loading and active operations never flash a setup warning', () => {
  assert.equal(transferGuideNotice(transfer({ refreshing: true, state: 'disabled' })), 'loading');
  assert.equal(transferGuideNotice(transfer({ state: 'loading', taildropTargets: 0 })), 'loading');
  assert.equal(transferGuideNotice(transfer({ state: 'disconnected', taildropTargets: 0 })), 'loading');
  assert.equal(transferGuideNotice(transfer({ busy: true, state: 'disabled' })), '');
  for (const override of [{ loading: true }, { busy: true }, { locked: true }, { connected: false }]) {
    assert.equal(taildriveGuideNotice(drive(override)), '');
  }
});

test('only a successful empty shallow Taildrive listing gets share setup help', () => {
  assert.equal(taildriveGuideNotice(drive({ path: '/', listedPath: '/' })), 'share');
  assert.equal(taildriveGuideNotice(drive({ path: '/tailnet', listedPath: '/tailnet' })), 'share');
  assert.equal(taildriveGuideNotice(drive()), 'share');
  assert.equal(taildriveGuideNotice(drive({ path: '/tailnet/device/docs', listedPath: '/tailnet/device/docs' })), '');
  assert.equal(taildriveGuideNotice(drive({ listedPath: '' })), '');
  assert.equal(taildriveGuideNotice(drive({ listedPath: '/' })), '');
  assert.equal(taildriveGuideNotice(drive({ entryCount: 1 })), '');
  assert.equal(taildriveGuideNotice(drive({ search: 'report' })), '');
});

test('permission help needs explicit list denial, never timeout or local authentication', () => {
  assert.equal(taildriveGuideNotice(drive({ reason: 'permission_denied', listFailure: true })), 'permission');
  assert.equal(taildriveGuideNotice(drive({ reason: 'permission_denied', listFailure: false })), '');
  for (const reason of ['timeout', 'remote_unavailable', 'backend_unavailable', 'folder_authentication_failed', 'not_found']) {
    assert.equal(taildriveGuideNotice(drive({ reason, listFailure: true })), '');
  }
});

test('context guides open centered dialogs without navigating away from the original surface', () => {
  const method = shell.match(/^  private openContextGuide\([\s\S]*?^  }/m)[0];
  assert.match(method, /canOpenContextGuide/);
  assert.doesNotMatch(method, /navigateTo|openSettingsDetail|settingsPathStack|deviceDetailVisible/);
  assert.match(method, /new CustomDialogController/);
  assert.match(method, /alignment: DialogAlignment.Center/);
  assert.match(device, /builder: FeatureSetupDialog/);
  assert.match(device, /alignment: DialogAlignment.Center/);
  assert.doesNotMatch(shell + device, /bindSheet\(\$\$?this\.(?:contextGuideVisible|setupGuideVisible)/);
  const assignments = shell.split('\n').filter(line => /contextGuideVisible = true/.test(line));
  assert.equal(assignments.length, 1);
});

test('functional entry points preserve LocalSend and existing file navigation', () => {
  assert.match(shell, /transfer-disabled-taildrop-help/);
  assert.match(shell, /transfer-localsend-target-help/);
  assert.match(shell, /transfer-help-menu/);
  assert.match(shell, /network-subnet-help/);
  assert.match(shell, /network-exit-help/);
  assert.match(files, /taildrive-setup-help-menu/);
  assert.match(files, /taildrive-clear-empty-search/);
  assert.match(files, /taildrive-empty-retry/);
  assert.match(files, /lastListedPath = this.path/);
  assert.match(files, /this.status === 'permission_denied'/);
  assert.match(shell, /onRequestConnection: \(\) => this.runConnectionAction\(\)/);
  assert.match(device, /mediaProbeState === 'available' \|\| this.mediaProbeState === 'unavailable'/);
});

test('focused tutorial filters sections and keeps advanced examples opt-in', () => {
  const method = guide.match(/^  private visibleSections\([\s\S]*?^  }/m)[0];
  const context = { FEATURE_GUIDE_SECTIONS: sandbox.sections };
  vm.runInNewContext(stripTypeScriptTypes(method.replace('  private ', 'function ')), context);
  assert.deepEqual(Array.from(context.visibleSections.call({ initialSection: 'taildrive' }), s => s.id), ['taildrive']);
  assert.deepEqual(Array.from(context.visibleSections.call({ initialSection: 'transfer' }), s => s.id), ['taildrop', 'localsend']);
  assert.equal(context.visibleSections.call({ initialSection: '' }).length, 10);
  assert.match(guide, /advancedSection: string = ''/);
  assert.match(guide, /this.advancedSection === section.id/);
});

test('all native entry resource names are present in English and Chinese', () => {
  for (const ref of new Set((shell + files + device + guide).match(/app\.string\.(?:feature_guide_[a-z_]+|action_login|action_connect)/g))) {
    for (const locale of locales) assert.ok(locale.some(s => 'app.string.' + s.name === ref), ref);
  }
});

test('busy and protected UI suppress contextual help without modifying account state', () => {
  const method = shell.match(/^  private canOpenContextGuide\([\s\S]*?^  }/m)[0];
  const runtime = {};
  vm.runInNewContext(stripTypeScriptTypes(method.replace('  private ', 'function ')), runtime);
  const ready = { appShellReady: true, appLockRequired: false, appLockAuthenticating: false,
    securitySettingsAuthenticating: false, taildropSendActive: () => false,
    taildropReceiveInProgress: false, taildropPickerOpen: false };
  assert.equal(runtime.canOpenContextGuide.call(ready), true);
  for (const flag of ['appLockRequired', 'appLockAuthenticating', 'securitySettingsAuthenticating', 'taildropReceiveInProgress', 'taildropPickerOpen']) {
    assert.equal(runtime.canOpenContextGuide.call({ ...ready, [flag]: true }), false);
  }
  assert.equal(runtime.canOpenContextGuide.call({ ...ready, taildropSendActive: () => true }), false);
  assert.match(files, /!this.previewDownloading && this.manualDownloadCount === 0/);
  assert.match(files, /!this.folderAccessAuthenticationInFlight && !this.folderPolicyAuthenticationInFlight/);
});

test('every manual context reopening resets focused chapter and collapsed advanced state', () => {
  assert.match(shell, /this.contextGuidePresentation\+\+/);
  assert.match(device, /this.setupGuidePresentation\+\+/);
  assert.match(guide, /@Prop @Watch\('onInitialSectionChanged'\) presentationId/);
  const changed = guide.match(/^  private onInitialSectionChanged\([\s\S]*?^  }/m)[0];
  assert.match(changed, /this.advancedSection = ''/);
  assert.match(changed, /this.expandedSection = this.initialSection/);
});
