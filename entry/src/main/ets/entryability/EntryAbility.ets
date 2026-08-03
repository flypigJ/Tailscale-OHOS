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
import { APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { AppShellFeatureAction, AppShellIntentAdapter } from '../services/AppShellIntentAdapter';
import { VpnBackgroundTaskManager } from '../services/VpnBackgroundTaskManager';
import { DiagnosticPrivacy } from '../services/DiagnosticPrivacy';
import { WindowEnvironment } from '../services/WindowEnvironment';

const DOMAIN = 0x0000;
const TAG = 'TailscaleOHOS';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private readonly vpnBackgroundTask: VpnBackgroundTaskManager = new VpnBackgroundTaskManager();
  private readonly appShellIntentAdapter: AppShellIntentAdapter = new AppShellIntentAdapter();
  private readonly windowEnvironment: WindowEnvironment = new WindowEnvironment();
  private appShellContentReady: boolean = false;
  private pendingAppShellFeatureActions: AppShellFeatureAction[] = [];

  private applyEdgeToEdge(colorMode?: ConfigurationConstant.ColorMode): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    const darkMode: boolean = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const shellPolicy = WindowEnvironment.shellWindowPolicy();
    if (shellPolicy.edgeToEdge) {
      mainWindow.setWindowLayoutFullScreen(true).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'Failed to enable edge-to-edge. %{public}s', DiagnosticPrivacy.formatLogError(error));
      });
    }
    if (shellPolicy.systemBarsVisible) {
      mainWindow.setWindowSystemBarEnable(['status', 'navigation']).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'Failed to keep system bars visible. %{public}s', DiagnosticPrivacy.formatLogError(error));
      });
    }
    // The freeform system title area remains system-owned and visible. HDS
    // title bars own content safe-area avoidance inside the edge-to-edge shell.
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000',
      navigationBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000'
    }).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Failed to update system bar colors. %{public}s', DiagnosticPrivacy.formatLogError(error));
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.vpnBackgroundTask.register();
    this.handleTaildropNotificationWant(want);
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate. ability=%{public}s reason=%{public}d',
      want.abilityName ?? '', launchParam.launchReason);
  }

  onDestroy(): void {
    this.windowEnvironment.detach();
    this.vpnBackgroundTask.unregister();
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
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
    this.requestNotificationAuthorization();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. code=%{public}d', err.code);
        return;
      }
      this.appShellContentReady = true;
      this.pendingAppShellFeatureActions.forEach((featureAction: AppShellFeatureAction) => {
        this.deliverAppShellFeatureAction(featureAction);
      });
      this.pendingAppShellFeatureActions = [];
      hilog.info(DOMAIN, TAG, 'pages/Index loaded');
    });
  }

  onWindowStageDestroy(): void {
    this.windowEnvironment.detach();
    this.mainWindow = undefined;
    this.appShellContentReady = false;
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.windowEnvironment.updateConfiguration(newConfig);
    this.applyEdgeToEdge(newConfig.colorMode);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.handleTaildropNotificationWant(want);
  }

  onForeground(): void {
    this.vpnBackgroundTask.onForeground(this.context);
    this.applyEdgeToEdge(this.context.config.colorMode);
    this.context.eventHub.emit(APP_FOREGROUND_EVENT);
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    this.vpnBackgroundTask.onBackground(this.context);
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }

  private handleTaildropNotificationWant(want: Want): void {
    const featureAction: AppShellFeatureAction = this.appShellIntentAdapter.toFeatureAction(want);
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

  private requestNotificationAuthorization(): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean) => {
      if (!enabled) {
        return notificationManager.requestEnableNotification(this.context);
      }
      return Promise.resolve();
    }).catch((error: BusinessError) => {
      hilog.info(DOMAIN, TAG, 'Notification authorization unavailable. code=%{public}d', error.code ?? -1);
    });
  }
}
