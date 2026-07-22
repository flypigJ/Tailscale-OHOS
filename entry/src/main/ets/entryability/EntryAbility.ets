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
import { APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';

const DOMAIN = 0x0000;
const TAG = 'TailscaleOHOS';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

  private applyEdgeToEdge(colorMode?: ConfigurationConstant.ColorMode): void {
    if (this.mainWindow === undefined) {
      return;
    }
    const darkMode: boolean = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.mainWindow.setWindowLayoutFullScreen(true).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Failed to enable edge-to-edge. message=%{public}s', `${error}`);
    });
    this.mainWindow.setWindowSystemBarEnable(['status', 'navigation']).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Failed to keep system bars visible. message=%{public}s', `${error}`);
    });
    this.mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000',
      navigationBarContentColor: darkMode ? '#FFFFFFFF' : '#FF000000'
    }).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Failed to update system bar colors. message=%{public}s', `${error}`);
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate. ability=%{public}s reason=%{public}d',
      want.abilityName ?? '', launchParam.launchReason);
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
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. code=%{public}d message=%{public}s',
          err.code, err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, 'pages/Index loaded');
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow = undefined;
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyEdgeToEdge(newConfig.colorMode);
  }

  onForeground(): void {
    this.applyEdgeToEdge(this.context.config.colorMode);
    this.context.eventHub.emit(APP_FOREGROUND_EVENT);
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }
}
