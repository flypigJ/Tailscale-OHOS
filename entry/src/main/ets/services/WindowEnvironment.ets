import { window, uiObserver, UIContext } from '@kit.ArkUI';
import { Configuration } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';

const DOMAIN = 0x0000;
const TAG = 'TailscaleOHOS';

export interface WindowEnvironmentRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface WindowEnvironmentAvoidArea {
  left: WindowEnvironmentRect;
  top: WindowEnvironmentRect;
  right: WindowEnvironmentRect;
  bottom: WindowEnvironmentRect;
}

/**
 * M12D keeps the three window responsibilities explicit. The policy is pure;
 * WindowEnvironment still owns the live window listeners and snapshots.
 */
export enum WindowShellResponsibility {
  EDGE_TO_EDGE_WINDOW = 'edge-to-edge-window',
  HDS_NAVIGATION_SAFE_AREA = 'hds-navigation-safe-area',
  SYSTEM_TITLE_AREA = 'system-title-area'
}

export interface ShellWindowPolicy {
  edgeToEdge: boolean;
  systemBarsVisible: boolean;
  freeformTitleAreaVisible: boolean;
  contentSafeAreaOwner: WindowShellResponsibility;
  titleAreaOwner: WindowShellResponsibility;
}

interface DensityUpdateObservation {
  density: number;
}

/**
 * Window inputs for responsive layout. WindowEnvironment remains a passive
 * snapshot owner; the Shell consumes only layout/safe-area responsibilities,
 * never page or business state.
 */
export interface WindowEnvironmentObservation {
  generation: number;
  listenerCount: number;
  windowRect: WindowEnvironmentRect;
  systemAvoidArea: WindowEnvironmentAvoidArea;
  navigationIndicatorAvoidArea: WindowEnvironmentAvoidArea;
  density: number;
  systemDensity: number;
  defaultDensity: number;
  customDensity: number;
  colorMode: number;
  direction: number;
}

const EMPTY_RECT: WindowEnvironmentRect = { left: 0, top: 0, width: 0, height: 0 };
function copyRect(rect: window.Rect): WindowEnvironmentRect {
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
}

function copyAvoidArea(area: window.AvoidArea): WindowEnvironmentAvoidArea {
  return {
    left: copyRect(area.leftRect),
    top: copyRect(area.topRect),
    right: copyRect(area.rightRect),
    bottom: copyRect(area.bottomRect)
  };
}

function emptyAvoidArea(): WindowEnvironmentAvoidArea {
  return {
    left: copyEmptyRect(),
    top: copyEmptyRect(),
    right: copyEmptyRect(),
    bottom: copyEmptyRect()
  };
}

function copyEmptyRect(): WindowEnvironmentRect {
  return { left: EMPTY_RECT.left, top: EMPTY_RECT.top, width: EMPTY_RECT.width, height: EMPTY_RECT.height };
}

function copyEnvironmentRect(rect: WindowEnvironmentRect): WindowEnvironmentRect {
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
}

/**
 * The sole owner of Window/UIContext listeners. Its callbacks only copy the
 * values delivered by their own API; they do not query another API, perform
 * I/O, update AppStorage, or invoke feature/business code.
 */
export class WindowEnvironment {
  private mainWindow?: window.Window;
  private uiContext?: UIContext;
  private active: boolean = false;
  private generation: number = 0;
  private listenerCount: number = 0;
  private windowSizeListenerRegistered: boolean = false;
  private avoidAreaListenerRegistered: boolean = false;
  private densityListenerRegistered: boolean = false;
  private observation: WindowEnvironmentObservation = {
    generation: 0,
    listenerCount: 0,
    windowRect: copyEmptyRect(),
    systemAvoidArea: emptyAvoidArea(),
    navigationIndicatorAvoidArea: emptyAvoidArea(),
    density: 0,
    systemDensity: 0,
    defaultDensity: 0,
    customDensity: 0,
    colorMode: 0,
    direction: 0
  };

  static shellWindowPolicy(): ShellWindowPolicy {
    return {
      edgeToEdge: true,
      systemBarsVisible: true,
      freeformTitleAreaVisible: true,
      contentSafeAreaOwner: WindowShellResponsibility.HDS_NAVIGATION_SAFE_AREA,
      titleAreaOwner: WindowShellResponsibility.SYSTEM_TITLE_AREA
    };
  }

  private readonly onWindowSizeChange = (size: window.Size): void => {
    if (!this.active) {
      return;
    }
    this.observation.windowRect = {
      left: this.observation.windowRect.left,
      top: this.observation.windowRect.top,
      width: size.width,
      height: size.height
    };
  };

  private readonly onAvoidAreaChange = (options: window.AvoidAreaOptions): void => {
    if (!this.active) {
      return;
    }
    if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
      this.observation.systemAvoidArea = copyAvoidArea(options.area);
    }
    if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.observation.navigationIndicatorAvoidArea = copyAvoidArea(options.area);
    }
  };

  private readonly onDensityUpdate = (densityInfo: DensityUpdateObservation): void => {
    if (!this.active) {
      return;
    }
    this.observation.density = densityInfo.density;
  };

  attach(mainWindow: window.Window, configuration: Configuration): void {
    if (this.active && this.mainWindow === mainWindow) {
      this.updateConfiguration(configuration);
      return;
    }
    this.detach();
    let uiContext: UIContext;
    try {
      uiContext = mainWindow.getUIContext();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'WindowEnvironment UI context unavailable. %{public}s',
        DiagnosticPrivacy.formatLogError(error as BusinessError));
      return;
    }
    this.mainWindow = mainWindow;
    this.uiContext = uiContext;
    this.active = true;
    this.generation += 1;
    this.observation.generation = this.generation;
    this.updateConfiguration(configuration);
    this.readInitialObservation(mainWindow);
    this.registerListeners(mainWindow, this.uiContext);
    this.logInitialObservation();
  }

  updateConfiguration(configuration: Configuration): void {
    if (!this.active) {
      return;
    }
    this.observation.colorMode = configuration.colorMode ?? 0;
    this.observation.direction = configuration.direction ?? 0;
  }

  detach(): void {
    const registeredWindow = this.mainWindow;
    const registeredContext = this.uiContext;
    this.active = false;
    this.mainWindow = undefined;
    this.uiContext = undefined;
    if (registeredWindow !== undefined) {
      this.unregisterListeners(registeredWindow, registeredContext);
    }
    this.listenerCount = 0;
    this.observation.listenerCount = 0;
  }

  getObservation(): WindowEnvironmentObservation {
    return {
      generation: this.observation.generation,
      listenerCount: this.observation.listenerCount,
      windowRect: copyEnvironmentRect(this.observation.windowRect),
      systemAvoidArea: this.copyObservationAvoidArea(this.observation.systemAvoidArea),
      navigationIndicatorAvoidArea: this.copyObservationAvoidArea(this.observation.navigationIndicatorAvoidArea),
      density: this.observation.density,
      systemDensity: this.observation.systemDensity,
      defaultDensity: this.observation.defaultDensity,
      customDensity: this.observation.customDensity,
      colorMode: this.observation.colorMode,
      direction: this.observation.direction
    };
  }

  private readInitialObservation(mainWindow: window.Window): void {
    try {
      this.observation.windowRect = copyRect(mainWindow.getWindowProperties().windowRect);
      this.observation.systemAvoidArea = copyAvoidArea(
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM));
      this.observation.navigationIndicatorAvoidArea = copyAvoidArea(
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR));
      const densityInfo = mainWindow.getWindowDensityInfo();
      this.observation.systemDensity = densityInfo.systemDensity;
      this.observation.defaultDensity = densityInfo.defaultDensity;
      this.observation.customDensity = densityInfo.customDensity;
      this.observation.density = densityInfo.customDensity > 0
        ? densityInfo.customDensity : densityInfo.defaultDensity;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'WindowEnvironment initial observation unavailable. %{public}s',
        DiagnosticPrivacy.formatLogError(error as BusinessError));
    }
  }

  private registerListeners(mainWindow: window.Window, uiContext: UIContext): void {
    try {
      mainWindow.on('windowSizeChange', this.onWindowSizeChange);
      this.windowSizeListenerRegistered = true;
      mainWindow.on('avoidAreaChange', this.onAvoidAreaChange);
      this.avoidAreaListenerRegistered = true;
      uiObserver.on('densityUpdate', uiContext, this.onDensityUpdate);
      this.densityListenerRegistered = true;
      this.listenerCount = 3;
      this.observation.listenerCount = this.listenerCount;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'WindowEnvironment listener registration unavailable. %{public}s',
        DiagnosticPrivacy.formatLogError(error as BusinessError));
      this.unregisterListeners(mainWindow, uiContext);
    }
  }

  private unregisterListeners(mainWindow: window.Window, uiContext?: UIContext): void {
    if (this.windowSizeListenerRegistered) {
      try {
        mainWindow.off('windowSizeChange', this.onWindowSizeChange);
      } catch (error) {
        this.logListenerCleanupError('windowSizeChange', error as BusinessError);
      }
      this.windowSizeListenerRegistered = false;
    }
    if (this.avoidAreaListenerRegistered) {
      try {
        mainWindow.off('avoidAreaChange', this.onAvoidAreaChange);
      } catch (error) {
        this.logListenerCleanupError('avoidAreaChange', error as BusinessError);
      }
      this.avoidAreaListenerRegistered = false;
    }
    if (this.densityListenerRegistered) {
      try {
        if (uiContext !== undefined) {
          uiObserver.off('densityUpdate', uiContext, this.onDensityUpdate);
        }
      } catch (error) {
        this.logListenerCleanupError('densityUpdate', error as BusinessError);
      }
      this.densityListenerRegistered = false;
    }
    this.listenerCount = 0;
    this.observation.listenerCount = 0;
  }

  private logListenerCleanupError(event: string, error: BusinessError): void {
    hilog.warn(DOMAIN, TAG, 'WindowEnvironment %{public}s listener cleanup unavailable. %{public}s',
      event, DiagnosticPrivacy.formatLogError(error));
  }

  private logInitialObservation(): void {
    const value = this.observation;
    hilog.info(DOMAIN, TAG,
      'WindowEnvironment active generation=%{public}d listeners=%{public}d rect=%{public}d,%{public}d,%{public}d,%{public}d systemTop=%{public}d navBottom=%{public}d density=%{public}.3f',
      value.generation, value.listenerCount, value.windowRect.left, value.windowRect.top,
      value.windowRect.width, value.windowRect.height, value.systemAvoidArea.top.height,
      value.navigationIndicatorAvoidArea.bottom.height, value.density);
  }

  private copyObservationAvoidArea(area: WindowEnvironmentAvoidArea): WindowEnvironmentAvoidArea {
    return {
      left: copyEnvironmentRect(area.left),
      top: copyEnvironmentRect(area.top),
      right: copyEnvironmentRect(area.right),
      bottom: copyEnvironmentRect(area.bottom)
    };
  }
}
