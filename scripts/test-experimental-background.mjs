import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { stripEtsModuleSyntax } from './helpers/ets-vm-loader.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/services/ExperimentalBackgroundService.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class ExperimentalBackgroundService', 'class ExperimentalBackgroundService'));
const serviceDir = new URL('../entry/src/main/ets/services/', import.meta.url);
const trafficJs = ['HomeReadOnlyGateway.ets', 'PipTrafficHistory.ets'].map(file =>
  stripEtsModuleSyntax(readFileSync(new URL(file, serviceDir), 'utf8'))).join('\n');
const settingsSource = readFileSync(new URL('../entry/src/main/ets/components/BackgroundRunningSettings.ets', import.meta.url), 'utf8');
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function fixture() {
  const f = { tasks: new Map(), next: 20, stops: [], location: false, permission: 0,
    rendererEvents: new Map(), pipEvents: new Map(), published: [], earlyCancel: false,
    audioStarted: 0, audioReleased: 0, audioSessions: [], audioDeactivated: 0,
    downloadStarted: 0, downloadStopped: 0, failAudio: false, failRelease: false,
    failPublish: false, pipActive: false, pipAutoStart: false, pipStops: 0,
    pipDisposed: 0, pipConfig: null, pipUpdatedSizes: [], records: [], listeners: new Set(),
    trafficTimers: new Map(), trafficFrames: [], trafficDisposed: 0, now: 2000, vpnStatus: '' };
  const renderer = {
    on: (name, cb) => f.rendererEvents.set(name, cb), off: name => f.rendererEvents.delete(name),
    start: async () => { if (f.failAudio) throw { code: 201 }; f.audioStarted++; },
    stop: async () => {},
    release: async () => { if (f.failRelease) throw { code: 9800004 }; f.audioReleased++; }
  };
  const pip = {
    on: (name, cb) => f.pipEvents.set(name, cb), off: name => f.pipEvents.delete(name),
    setAutoStartEnabled: enable => { f.pipAutoStart = enable; },
    updateContentSize: (width, height) => { f.pipUpdatedSizes.push({ width, height }); },
    startPiP: async () => { f.pipActive = true; },
    stopPiP: async () => { f.pipStops++; f.pipActive = false; },
    isPiPActive: async () => f.pipActive
  };
  let nextTimer = 1;
  const box = {
    Date: { now: () => f.now },
    fileIo: { readTextSync: path => { assert.equal(path, '/files/vpn-probe-status.txt'); return f.vpnStatus; } },
    setInterval: (callback, delay) => {
      assert.equal(delay, 1000); const id = nextTimer++; f.trafficTimers.set(id, callback); return id;
    },
    clearInterval: id => f.trafficTimers.delete(id),
    PipTrafficChart: class {
      update(rates) { f.trafficFrames.push(JSON.parse(JSON.stringify(rates))); }
      dispose() { f.trafficDisposed++; }
    },
    DiagnosticEventStore: { record: (...args) => f.records.push(args) },
    SimulatedDownload: class {
      async start(progress, failed) { f.downloadStarted++; f.progress = progress; f.downloadFailed = failed; }
      async stop() { f.downloadStopped++; }
    },
    backgroundTaskManager: {
      ContinuousTaskRequest: class {},
      BackgroundTaskMode: { MODE_LOCATION: 4, MODE_AUDIO_PLAYBACK: 2, MODE_DATA_TRANSFER: 1 },
      BackgroundTaskSubmode: { SUBMODE_NORMAL_NOTIFICATION: 2, SUBMODE_LIVE_VIEW_NOTIFICATION: 3 },
      on: (_name, cb) => { f.cancel = cb; }, off() {},
      startBackgroundRunning: async (_context, request) => {
        const task = { notificationId: ++f.next, continuousTaskId: ++f.next, request };
        f.tasks.set(task.continuousTaskId, task);
        if (f.earlyCancel) { f.tasks.delete(task.continuousTaskId); f.cancel({ id: task.continuousTaskId, reason: 1 }); }
        return task;
      },
      stopBackgroundRunning: async (_context, id) => {
        assert.equal(typeof id, 'number', 'must target one owned task'); f.stops.push(id); f.tasks.delete(id);
      },
      getAllContinuousTasks: async () => [...f.tasks.values()].map(t => ({ ...t, abilityName: 'EntryAbility' }))
    },
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({}) },
    abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({ authResults: [f.permission] }) }) },
    geoLocationManager: { isLocationEnabled: () => true,
      LocationRequestPriority: { LOW_POWER: 1 }, LocationRequestScenario: { UNSET: 0 },
      on: () => { f.location = true; }, off: () => { f.location = false; } },
    audio: {
      AudioSamplingRate: { SAMPLE_RATE_48000: 48000 }, AudioChannel: { CHANNEL_2: 2 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
      StreamUsage: { STREAM_USAGE_MUSIC: 1, STREAM_USAGE_NAVIGATION: 13 },
      AudioDataCallbackResult: { VALID: 0 },
      AudioConcurrencyMode: { CONCURRENCY_MIX_WITH_OTHERS: 1 },
      InterruptForceType: { INTERRUPT_FORCE: 0, INTERRUPT_SHARE: 1 },
      InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_DUCK: 4 },
      getAudioManager: () => ({
        getSessionManager: () => ({
          activateAudioSession: async strategy => f.audioSessions.push(strategy),
          deactivateAudioSession: async () => { f.audioDeactivated++; }
        })
      }),
      createAudioRenderer: async options => { f.audioOptions = options; return renderer; }
    },
    PiPWindow: { isPiPEnabled: () => true, PiPTemplateType: { VIDEO_PLAY: 0 },
      PiPState: { ABOUT_TO_START: 1, STARTED: 2, ABOUT_TO_STOP: 3, STOPPED: 4, ERROR: 6 },
      create: async config => { f.pipConfig = config; return pip; } },
    typeNode: { createNode: () => ({ dispose: () => { f.pipDisposed++; } }) },
    XComponentController: class {}, XComponentType: { SURFACE: 0 },
    notificationManager: { SlotType: { LIVE_VIEW: 1 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 1 },
      publish: async request => {
        if (f.failPublish) throw { code: 1600004 };
        f.published.push(request);
      } }
  };
  vm.runInNewContext(trafficJs + '\n' + js + '\nglobalThis.Service = ExperimentalBackgroundService;', box);
  f.service = box.Service.instance();
  f.service.initialize({ filesDir: '/files', resourceManager: { getStringByNameSync: () => 'Simulated download' } });
  f.set = (mode, enabled) => f.service.setEnabled(mode, enabled, {});
  return f;
}

function createSettingsHarness(f) {
  const componentStart = settingsSource.indexOf('@Component');
  const logicEnd = settingsSource.indexOf('@Builder', componentStart);
  assert.ok(componentStart >= 0 && logicEnd > componentStart);
  const logicTs = settingsSource.slice(componentStart, logicEnd)
    .replace(/^import .*;\r?$/gm, '')
    .replace(/@Component\r?\n/, '')
    .replace('export struct BackgroundRunningSettings', 'class BackgroundRunningSettings')
    .replace(/@Prop\s+/g, '')
    .replace(/@State\s+/g, '') + '\n}';
  const logicJs = stripTypeScriptTypes(logicTs);
  const rendered = { location: false, pip: false, audio: false, download: false };
  const box = {
    ExperimentalBackgroundService: { instance: () => f.service },
    Scroller: class {},
    $r: () => ({})
  };
  vm.runInNewContext(logicJs + '\nglobalThis.Settings = BackgroundRunningSettings;', box);
  const component = new box.Settings();
  component.getUIContext = () => ({});
  component.aboutToAppear();

  // Mirror ArkUI Toggle(isOn) reconciliation: if @State disagrees with the native
  // switch after a render frame, ArkUI snaps Toggle back and queues onChange(stateVal).
  const reconcile = () => {
    for (const mode of ['location', 'pip', 'audio', 'download']) {
      const stateVal = component.modeEnabled(mode);
      if (rendered[mode] !== stateVal) {
        rendered[mode] = stateVal;
        queueMicrotask(() => component.onToggleChange(mode, stateVal));
      }
    }
  };
  const userTap = async mode => {
    const nextVal = !rendered[mode];
    rendered[mode] = nextVal;
    component.onToggleChange(mode, nextVal);
    reconcile();
    await flush();
    reconcile();
    await flush();
  };
  return { component, rendered, userTap };
}

test('all four experimental controls default to off without starting any resource', () => {
  const f = fixture();
  for (const mode of ['location', 'pip', 'audio', 'download']) assert.equal(f.service.isActive(mode), false);
  assert.equal(f.tasks.size, 0); assert.equal(f.audioStarted, 0); assert.equal(f.downloadStarted, 0);
});

test('location permission denial leaves no background task, and accepted location cleans up its own task', async () => {
  const f = fixture(); f.permission = -1; await f.set('location', true);
  assert.equal(f.service.isActive('location'), false); assert.equal(f.tasks.size, 0);
  assert.equal(f.service.lastError(), 201);
  f.permission = 0; await f.set('location', true); assert.equal(f.location, true);
  const id = [...f.tasks.keys()][0]; await f.set('location', false);
  assert.equal(f.location, false); assert.deepEqual(f.stops, [id]);
});

test('audio uses navigation usage with concurrent session, writes silent frames, and releases on stop', async () => {
  const f = fixture(); const cb = () => {}; f.service.subscribe(cb);
  await f.set('audio', true); f.service.unsubscribe(cb);
  assert.equal(f.service.isActive('audio'), true);
  assert.equal(f.audioOptions.rendererInfo.usage, 13);
  assert.equal(f.audioSessions.length, 1);
  assert.equal(f.audioSessions[0].concurrencyMode, 1);
  const buffer = new ArrayBuffer(16); new Uint8Array(buffer).fill(99);
  f.rendererEvents.get('writeData')(buffer); assert.ok([...new Uint8Array(buffer)].every(x => x === 0));
  await f.set('audio', false); assert.equal(f.audioReleased, 1); assert.equal(f.audioDeactivated, 1);
  assert.equal(f.tasks.size, 0);
});

test('a partial audio startup failure rolls back renderer and only the owned task', async () => {
  const f = fixture(); f.failAudio = true; await f.set('audio', true);
  assert.equal(f.audioReleased, 1); assert.equal(f.tasks.size, 0);
  assert.equal(f.service.isActive('audio'), false); assert.equal(f.service.lastError(), 201);
});

test('failed cleanup remains visible and can be retried', async () => {
  const f = fixture(); await f.set('audio', true); f.failRelease = true;
  await f.set('audio', false); assert.equal(f.service.isActive('audio'), true);
  f.failRelease = false; await f.set('audio', false);
  assert.equal(f.service.isActive('audio'), false); assert.equal(f.tasks.size, 0);
});

test('system cancellation stops the matching experiment and leaves other experiments and VPN task untouched', async () => {
  const f = fixture(); await f.set('location', true); await f.set('audio', true);
  f.cancel({ id: 99999, reason: 1 }); await flush(); assert.equal(f.tasks.size, 2);
  const [locationId, audioId] = [...f.tasks.keys()]; f.tasks.delete(locationId);
  f.cancel({ id: locationId, reason: 1 }); await flush();
  assert.equal(f.service.isActive('location'), false); assert.equal(f.service.isActive('audio'), true);
  assert.equal(f.tasks.has(audioId), true); assert.equal(f.stops.length, 0);
});

test('cancellation before start resolves never leaves an active resource or retries itself', async () => {
  const f = fixture(); f.earlyCancel = true; await f.set('audio', true); await flush();
  assert.equal(f.audioStarted, 0); assert.equal(f.tasks.size, 0); assert.equal(f.service.isActive('audio'), false);
});

test('PiP closure and forced audio focus interruption update switches without resurrection', async () => {
  const f = fixture(); await f.set('pip', true); assert.equal(f.pipActive, true);
  assert.equal(f.pipAutoStart, true);
  assert.equal(f.pipConfig.contentWidth, 96);
  assert.equal(f.pipConfig.contentHeight, 96);
  assert.equal(f.pipConfig.defaultWindowSizeType, 1);
  assert.equal(f.pipConfig.cornerAdsorptionEnabled, true);
  assert.deepEqual([...f.pipConfig.controlGroups], []);
  assert.deepEqual(f.pipUpdatedSizes.map(item => ({ width: item.width, height: item.height })),
    [{ width: 96, height: 96 }]);
  f.pipActive = false; f.pipEvents.get('stateChange')(4); await flush();
  assert.equal(f.service.isActive('pip'), false);
  assert.equal(f.service.lastError(), 0);
  assert.equal(f.pipDisposed, 1);
  assert.equal(f.trafficDisposed, 1);
  assert.equal(f.trafficTimers.size, 0);
  await f.set('audio', true);
  f.rendererEvents.get('audioInterrupt')({ forceType: 1, hintType: 4 }); await flush();
  assert.equal(f.service.isActive('audio'), true);
  f.rendererEvents.get('audioInterrupt')({ forceType: 0, hintType: 2 }); await flush();
  assert.equal(f.service.isActive('audio'), false); assert.equal(f.audioStarted, 1);
});

test('PiP plots read-only rates from advancing VPN heartbeats and clears a stale or replaced session', async () => {
  const f = fixture();
  const sample = (ms, session, rx, tx) => {
    f.now = ms;
    f.vpnStatus = `OK | state=Running | tun=true | trafficSession=${session} | rxBytes=${rx} | txBytes=${tx} | heartbeatMs=${ms}`;
    for (const tick of f.trafficTimers.values()) tick();
  };
  sample(10000, 1, 800, 100);
  await f.set('pip', true);
  assert.ok(f.pipConfig.customUIController);
  assert.equal(f.trafficTimers.size, 1);
  assert.deepEqual(f.trafficFrames, []);
  sample(12000, 1, 1800, 150);
  sample(12000, 1, 1800, 150);
  assert.deepEqual(f.trafficFrames, [[{ down: 500, up: 25 }]]);
  sample(13000, 2, 40, 20);
  assert.deepEqual(f.trafficFrames.at(-1), []);
  sample(14000, 2, 40, 20);
  assert.deepEqual(f.trafficFrames.at(-1), [{ down: 0, up: 0 }]);
  f.now = 20000;
  for (const tick of f.trafficTimers.values()) tick();
  assert.deepEqual(f.trafficFrames.at(-1), []);
  await f.set('pip', false);
  assert.equal(f.trafficTimers.size, 0);
  assert.equal(f.trafficDisposed, 1);
});

test('stopMode stops stashed PiP even when isPiPActive returns false and disposes node', async () => {
  const f = fixture(); await f.set('pip', true);
  f.pipActive = false;
  await f.set('pip', false);
  assert.equal(f.pipStops, 1);
  assert.equal(f.pipAutoStart, false);
  assert.equal(f.pipDisposed, 1);
  assert.equal(f.service.isActive('pip'), false);
});

test('download notification failure logs warning without cancelling active download', async () => {
  const f = fixture(); f.failPublish = true;
  await f.set('download', true); f.progress(4096); await flush();
  assert.equal(f.service.isActive('download'), true);
  assert.ok(f.records.some(r => r[2] === 'experiment_notification_failed_download' && r[4] === 1600004));
});

test('download notification reflects received bytes and shutdown cleans every owned experiment', async () => {
  const f = fixture(); await f.set('download', true); f.progress(8192); await flush();
  assert.equal(f.published.length, 1); assert.equal(f.published[0].content.systemLiveView.text, '8192 B');
  await f.set('location', true); await f.set('pip', true); await f.set('audio', true);
  f.service.shutdown(); await flush();
  for (const mode of ['location', 'pip', 'audio', 'download']) assert.equal(f.service.isActive(mode), false);
  assert.equal(f.tasks.size, 0); assert.equal(f.location, false); assert.equal(f.pipActive, false);
});

test('settings toggle prevents self-cancellation on fast PiP start and reverts cleanly on failed location start', async () => {
  const f = fixture();
  const h = createSettingsHarness(f);
  await h.userTap('pip');
  assert.equal(f.service.isActive('pip'), true);
  assert.equal(h.component.pipEnabled, true);
  assert.equal(h.rendered.pip, true);
  assert.equal(f.records.filter(r => r[2] === 'experiment_stopped_pip').length, 0);

  await h.userTap('pip');
  assert.equal(f.service.isActive('pip'), false);
  assert.equal(h.component.pipEnabled, false);
  assert.equal(f.records.filter(r => r[2] === 'experiment_stopped_pip').length, 1);

  f.permission = -1;
  await h.userTap('location');
  assert.equal(f.service.isActive('location'), false);
  assert.equal(h.component.locationEnabled, false);
  assert.equal(h.rendered.location, false);
  assert.equal(h.component.errorCode, 201);
});

test('ModeRow uses single object-literal pass-by-reference and every mode turns on and off cleanly in one tap', async () => {
  assert.match(settingsSource, /@Builder\s+private\s+ModeRow\(\$\$:\s*BackgroundModeRowData\)/);
  assert.match(settingsSource, /Toggle\(\{\s*type:\s*ToggleType\.Switch,\s*isOn:\s*\$\$\.isOn\s*\}\)/);
  assert.match(settingsSource, /\.enabled\(!\$\$\.busy\)/);
  assert.match(settingsSource, /LightAppearance\.control\(\$\$\.glowLevel\)/);
  assert.doesNotMatch(settingsSource, /this\.ModeRow\(\s*['"]/);
  const objectCalls = settingsSource.match(/this\.ModeRow\(\{/g) ?? [];
  assert.equal(objectCalls.length, 4);

  const f = fixture();
  const h = createSettingsHarness(f);
  for (const mode of ['location', 'pip', 'audio', 'download']) {
    await h.userTap(mode);
    assert.equal(f.service.isActive(mode), true, `${mode} should stay active after first tap`);
    assert.equal(h.component.modeEnabled(mode), true);
    assert.equal(h.rendered[mode], true);
    assert.equal(f.records.filter(r => r[2] === `experiment_stopped_${mode}`).length, 0);

    await h.userTap(mode);
    assert.equal(f.service.isActive(mode), false, `${mode} should stop after second single tap`);
    assert.equal(h.component.modeEnabled(mode), false);
    assert.equal(h.rendered[mode], false);
    assert.equal(f.records.filter(r => r[2] === `experiment_stopped_${mode}`).length, 1);
  }
});
