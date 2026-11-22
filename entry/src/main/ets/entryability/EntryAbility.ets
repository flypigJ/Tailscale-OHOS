import {
  AbilityConstant,
  Configuration,
  ConfigurationConstant,
  UIAbility,
  Want
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { APP_BACKGROUND_EVENT, APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { AppShellFeatureAction, AppShellIntentAdapter } from '../services/AppShellIntentAdapter';
import { VpnBackgroundTaskManager } from '../services/VpnBackgroundTaskManager';
import { DiagnosticPrivacy } from '../services/DiagnosticPrivacy';
import { WindowEnvironment } from '../services/WindowEnvironment';
import { SystemShareInbox } from '../services/SystemShareInbox';
import { CrashDiagnosticService } from '../services/CrashDiagnosticService';
import { RuntimeDiagnosticService } from '../services/RuntimeDiagnosticService';
import { ExperimentalBackgroundService } from '../services/ExperimentalBackgroundService';
import { PersonalizationPreferences } from '../services/PersonalizationPreferences';
import { AppSecurityPreferences } from '../services/AppSecurityPreferences';

const DOMAIN = 0x0000;
const TAG = 'TailscaleOHOS';

export default class EntryAbility extends UIAbility {
  private readonly runtimeDiagnostic: RuntimeDiagnosticService = new RuntimeDiagnosticService();
  private mainWindow?: window.Window;
  private readonly vpnBackgroundTask: VpnBackgroundTaskManager = new VpnBackgroundTaskManager();
  private readonly appShellIntentAdapter: AppShellIntentAdapter = new AppShellIntentAdapter();
  private readonly windowEnvironment: WindowEnvironment = new WindowEnvironment();
  private appShellContentReady: boolean = false;
  private windowStageGeneration: number = 0;
  private pendingAppShellFeatureActions: AppShellFeatureAction[] = [];

  private applyEdgeToEdge(colorMode?: ConfigurationConstant.ColorMode): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    let armed: boolean = false;
    try {
      if (typeof AppSecurityPreferences.isPrivacyProtectionArmedSync === 'function') {
        armed = AppSecurityPreferences.isPrivacyProtectionArmedSync(this.context.filesDir);
      }
    } catch (_error) {
      armed = true;
    }
    if (armed && typeof mainWindow.setWindowPrivacyMode === 'function') {
      this.applyWindowOperation(() => mainWindow.setWindowPrivacyMode(true));
    }
    const darkMode: boolean = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const shellPolicy = WindowEnvironment.shellWindowPolicy();
    if (shellPolicy.edgeToEdge) {
      this.applyWindowOperation(() => mainWindow.setWindowLayoutFullScreen(true));
    }
    if (shellPolicy.systemBarsVisible) {
      this.applyWindowOperation(() => mainWindow.setWindowSystemBarEnable(['status', 'navigation']));
    }
    // The freeform system title area remains system-owned and visible. HDS
    // title bars own content safe-area avoidance inside the edge-to-edge shell.
    this.applyWindowOperation(() => mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000',
      navigationBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000'
    }));
  }

  private async applyWindowOperation(operation: () => Promise<void>): Promise<void> {
    try {
      // Platform calls can throw before returning their Promise, especially
      // when the system window is already being destroyed.
      await operation();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Window update unavailable. %{public}s', DiagnosticPrivacy.formatLogError(error));
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.runtimeDiagnostic.start(this.context.filesDir, 'ui', launchParam);
    ExperimentalBackgroundService.instance().initialize(this.context);
    CrashDiagnosticService.initialize(this.context.filesDir);
    SystemShareInbox.receive(want);
    this.vpnBackgroundTask.register(this.context);
    this.handleTaildropNotificationWant(want);
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate. ability=%{public}s reason=%{public}d',
      want.abilityName ?? '', launchParam.launchReason);
  }

  onDestroy(): void {
    this.windowStageGeneration++;
    this.appShellContentReady = false;
    this.mainWindow = undefined;
    ExperimentalBackgroundService.instance().shutdown();
    this.runtimeDiagnostic.stop();
    CrashDiagnosticService.shutdown();
    this.windowEnvironment.detach();
    this.vpnBackgroundTask.unregister();
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const generation: number = ++this.windowStageGeneration;
    this.appShellContentReady = false;
    this.mainWindow = undefined;
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate');
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Failed to get main window. code=%{public}d', businessError.code);
    }
    this.applyEdgeToEdge(this.context.config.colorMode);
    if (this.mainWindow !== undefined) {
      this.windowEnvironment.attach(this.mainWindow, this.context.config);
    }
    this.requestNotificationAuthorization(generation);
    try {
      windowStage.loadContent('pages/Index', (err) => {
        if (generation !== this.windowStageGeneration) {
          return;
        }
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. code=%{public}d', err.code);
          return;
        }
        this.appShellContentReady = true;
        // The application color-mode API requires a created window and loaded content.
        this.applyPersonalizationColorMode();
        this.pendingAppShellFeatureActions.forEach((featureAction: AppShellFeatureAction) => {
          this.deliverAppShellFeatureAction(featureAction);
        });
        this.pendingAppShellFeatureActions = [];
        hilog.info(DOMAIN, TAG, 'pages/Index loaded');
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. %{public}s',
        DiagnosticPrivacy.formatLogError(error));
    }
  }

  onWindowStageDestroy(): void {
    this.windowStageGeneration++;
    this.windowEnvironment.detach();
    this.mainWindow = undefined;
    this.appShellContentReady = false;
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  private applyPersonalizationColorMode(): void {
    try {
      const settings = PersonalizationPreferences.load(this.context.filesDir);
      PersonalizationPreferences.applyColorMode(this.context, settings.colorMode);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Appearance update unavailable. %{public}s',
        DiagnosticPrivacy.formatLogError(error));
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.windowEnvironment.updateConfiguration(newConfig);
    this.applyEdgeToEdge(newConfig.colorMode);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    SystemShareInbox.receive(want);
    this.handleTaildropNotificationWant(want);
  }

  onForeground(): void {
    this.runtimeDiagnostic.mark('ui_foreground');
    this.vpnBackgroundTask.onForeground(this.context);
    this.applyEdgeToEdge(this.context.config.colorMode);
    this.context.eventHub.emit(APP_FOREGROUND_EVENT);
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    this.runtimeDiagnostic.mark('ui_background');
    this.context.eventHub.emit(APP_BACKGROUND_EVENT);
    this.vpnBackgroundTask.onBackground(this.context);
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }

  private handleTaildropNotificationWant(want: Want): void {
    const featureAction: AppShellFeatureAction =
      this.appShellIntentAdapter.toFeatureAction(want, this.context.filesDir);
    if (!this.appShellContentReady) {
      this.pendingAppShellFeatureActions.push(featureAction);
      return;
    }
    this.deliverAppShellFeatureAction(featureAction);
  }

  private deliverAppShellFeatureAction(featureAction: AppShellFeatureAction): void {
    if (featureAction.openTaildropInbox) {
      AppStorage.setOrCreate('taildropOpenInbox', Date.now());
    }
    if (featureAction.taildropNotificationAction.length > 0) {
      AppStorage.setOrCreate('taildropNotificationAction', featureAction.taildropNotificationAction);
    }
  }

  private async requestNotificationAuthorization(generation: number): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled && generation === this.windowStageGeneration) {
        await notificationManager.requestEnableNotification(this.context);
      }
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'Notification authorization unavailable. %{public}s',
        DiagnosticPrivacy.formatLogError(error));
    }
  }
}
