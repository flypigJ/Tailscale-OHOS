import nativeBridge from 'libtailscale_ohos.so';
import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  BlurStrategy,
  DividerMode,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  ScrollEffectType,
  hdsEffect,
  hdsMaterial
} from '@kit.UIDesignKit';

const MIN_CONNECTION_LOADING_MS: number = 1400;

interface ExitNodeChoice {
  id: string;
  name: string;
  online: boolean;
  selected: boolean;
}

interface PeerSummary {
  key: string;
  name: string;
  os: string;
  deviceModel: string;
  deviceType: string;
  addresses: string[];
  online: boolean;
  exitNode: boolean;
}

interface NetworkSettings {
  routeAll: boolean;
  corpDNS: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface AccountSummary {
  displayName: string;
  loginName: string;
  profilePicURL: string;
  tailnetName: string;
  deviceName: string;
  addresses: string[];
}

@Component
export struct BridgeStatus {
  @State nativeStatus: string = 'Go Bridge Pending';
  @State engineStatus: string = 'Tailscale Engine Pending';
  @State backendStatus: string = 'Tailscale Backend Stopped';
  @State loginHandoffStatus: string = 'Secure Login Pending';
  @State controlProbeStatus: string = 'Control TLS Probe Pending';
  @State vpnStatus: string = 'HarmonyOS VPN Extension Stopped';
  @State magicDNSProbeStatus: string = 'MagicDNS Probe Pending';
  @State exitNodes: ExitNodeChoice[] = [];
  @State peers: PeerSummary[] = [];
  @State networkSettings: NetworkSettings = {
    routeAll: true,
    corpDNS: true,
    exitNodeAllowLANAccess: false
  };
  @State networkSettingStatus: string = '';
  @State accountSummary: AccountSummary = {
    displayName: '',
    loginName: '',
    profilePicURL: '',
    tailnetName: '',
    deviceName: '',
    addresses: []
  };
  @State avatarLoadFailed: boolean = false;
  @State tailscaleVersion: string = '—';
  @State exitNodeStatus: string = '未使用出口节点';
  @State logoutStatus: string = '';
  @State diagnosticsUnlocked: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State loginInProgress: boolean = false;
  @State connectInProgress: boolean = false;
  @State backendReady: boolean = false;
  @State devicesLoading: boolean = true;
  @State hasAuthenticatedSession: boolean = false;
  @State currentTab: number = 0;
  @State glowLevel: number = 3;
  @State layoutWidth: number = 360;
  @State expandedPeerKeys: string[] = [];
  private connectionPollTimer: number = -1;
  private connectionCompletionTimer: number = -1;
  private connectionStartedAtMs: number = 0;
  private healthPollTimer: number = -1;
  private loginPollTimer: number = -1;
  private magicDNSProbeUrl: string = '';
  private settingsScroller: Scroller = new Scroller();
  private diagnosticsTapCount: number = 0;
  private diagnosticsLastTapMs: number = 0;

  aboutToAppear(): void {
    this.loadGlowLevel();
    this.resetDiagnosticsMode();
    this.backendReady = false;
    this.devicesLoading = true;
    this.verifyNativeBridge();
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    if (!vpnIsLive) {
      this.startBackend();
      setTimeout(() => this.refreshBackendStatus(), 1500);
    } else {
      this.backendReady = true;
      this.devicesLoading = false;
      this.hasAuthenticatedSession = true;
    }
    // Recheck after the heartbeat freshness window. This covers an extension
    // process that was killed just before the UI appeared (for example during
    // an application update) while its last heartbeat still looked current.
    setTimeout(() => {
      if (!this.refreshVpnProbeStatus()) {
        this.startBackend();
        setTimeout(() => this.refreshBackendStatus(), 1500);
      }
    }, 6000);
    this.startHealthPolling();
  }

  aboutToDisappear(): void {
    this.stopConnectionPolling();
    this.clearConnectionCompletionTimer();
    this.stopHealthPolling();
    this.stopLoginPolling();
    this.resetDiagnosticsMode();
  }

  private verifyNativeBridge(): void {
    try {
      this.nativeStatus = nativeBridge.hello();
      this.tailscaleVersion = nativeBridge.tailscaleVersion();
    } catch (error) {
      this.nativeStatus = `Go Bridge Failed: ${JSON.stringify(error)}`;
    }
  }

  private probeUserspaceEngine(): void {
    try {
      this.engineStatus = nativeBridge.probeEngine();
    } catch (error) {
      this.engineStatus = `Tailscale Engine Failed: ${JSON.stringify(error)}`;
    }
  }

  private startBackend(): void {
    this.backendReady = false;
    this.devicesLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.backendStatus = nativeBridge.backendStart(`${context.filesDir}/tailscale`, this.deviceModel());
    } catch (error) {
      this.backendStatus = `Tailscale Backend Failed: ${JSON.stringify(error)}`;
      this.backendReady = true;
      this.devicesLoading = false;
    }
  }

  private deviceModel(): string {
    const marketName: string = deviceInfo.marketName.trim();
    if (marketName.length > 0 && marketName !== 'default') {
      return marketName;
    }
    return deviceInfo.productModel.trim();
  }

  private refreshBackendStatus(): void {
    try {
      this.backendStatus = nativeBridge.backendStatus();
      if (this.backendStatus.includes('state=Running')) {
        this.backendReady = true;
        this.devicesLoading = true;
        this.hasAuthenticatedSession = true;
        this.refreshExitNodes();
        this.refreshPeers();
        this.refreshNetworkSettings();
        this.refreshAccount();
      } else if (this.needsLogin()) {
        this.backendReady = true;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = false;
        this.peers = [];
        this.exitNodes = [];
        this.accountSummary = {
          displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: []
        };
      } else if (this.backendStatus.startsWith('FAILED')) {
        this.backendReady = true;
        this.devicesLoading = false;
      }
    } catch (error) {
      this.backendStatus = `Tailscale Backend Failed: ${JSON.stringify(error)}`;
      this.backendReady = true;
      this.devicesLoading = false;
    }
  }

  private refreshExitNodes(): void {
    try {
      const choicesText: string = nativeBridge.backendExitNodes();
      this.exitNodes = JSON.parse(choicesText) as ExitNodeChoice[];
      const selected: ExitNodeChoice | undefined = this.exitNodes.find(
        (choice: ExitNodeChoice) => choice.selected);
      this.exitNodeStatus = selected === undefined ? '未使用出口节点' : `已选择：${selected.name}`;
    } catch (_error) {
      this.exitNodes = [];
      this.exitNodeStatus = '出口节点列表暂不可用';
    }
  }

  private setExitNode(id: string): void {
    try {
      this.exitNodeStatus = nativeBridge.backendSetExitNode(id);
      if (!this.exitNodeStatus.startsWith('FAILED')) {
        this.refreshExitNodes();
      }
    } catch (_error) {
      this.exitNodeStatus = 'FAILED | exit node | update unavailable';
    }
  }

  private refreshPeers(): void {
    try {
      const peersText: string = nativeBridge.backendPeers();
      this.peers = JSON.parse(peersText) as PeerSummary[];
    } catch (_error) {
      this.peers = [];
    }
    this.devicesLoading = false;
  }

  private refreshAccount(): void {
    try {
      const accountText: string = nativeBridge.backendAccount();
      const backendAccount: AccountSummary = JSON.parse(accountText) as AccountSummary;
      this.accountSummary = {
        displayName: backendAccount.displayName,
        loginName: backendAccount.loginName,
        profilePicURL: backendAccount.profilePicURL,
        tailnetName: backendAccount.tailnetName,
        deviceName: backendAccount.deviceName.length > 0 ? backendAccount.deviceName : this.deviceModel(),
        addresses: backendAccount.addresses
      };
      this.avatarLoadFailed = false;
    } catch (_error) {
      this.accountSummary = {
        displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: []
      };
      this.avatarLoadFailed = false;
    }
  }

  private refreshNetworkSettings(): void {
    try {
      const settingsText: string = nativeBridge.backendNetworkSettings();
      this.networkSettings = JSON.parse(settingsText) as NetworkSettings;
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | unavailable';
    }
  }

  private setNetworkSetting(key: string, enabled: boolean): void {
    try {
      this.networkSettingStatus = nativeBridge.backendSetNetworkSetting(key, enabled);
      if (!this.networkSettingStatus.startsWith('FAILED')) {
        this.refreshNetworkSettings();
        this.refreshBackendStatus();
      }
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | update unavailable';
    }
  }

  private openSecureLogin(): void {
    if (this.loginInProgress) {
      return;
    }
    this.loginInProgress = true;
    this.loginHandoffStatus = 'Preparing secure login';
    this.stopLoginPolling();
    // Keep one visible frame for the in-button LoadingProgress before a fast
    // handoff switches the foreground application to the system browser.
    this.loginPollTimer = setTimeout(() => this.pollSecureLogin(0), 600);
  }

  private pollSecureLogin(attempt: number): void {
    try {
      const authUrl: string = nativeBridge.backendAuthURL();
      if (authUrl.startsWith('PENDING')) {
        if (attempt >= 24) {
          this.loginHandoffStatus = 'FAILED | login URL | timed out';
          this.loginInProgress = false;
          return;
        }
        this.loginPollTimer = setTimeout(() => this.pollSecureLogin(attempt + 1), 400);
        return;
      }
      if (!authUrl.startsWith('https://login.tailscale.com/')) {
        this.loginHandoffStatus = authUrl.startsWith('FAILED') ? authUrl :
          'FAILED | login URL | rejected unexpected origin';
        this.loginInProgress = false;
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.loginHandoffStatus = 'Opening secure login in system browser';
      context.openLink(authUrl, { appLinkingOnly: false })
        .then(() => {
          this.loginHandoffStatus = 'Secure login page opened';
          this.loginInProgress = false;
        })
        .catch(() => {
          this.loginHandoffStatus = 'FAILED | secure browser handoff';
          this.loginInProgress = false;
        });
    } catch (error) {
      this.loginHandoffStatus = `FAILED | secure browser handoff | ${JSON.stringify(error)}`;
      this.loginInProgress = false;
    }
  }

  private stopLoginPolling(): void {
    if (this.loginPollTimer >= 0) {
      clearTimeout(this.loginPollTimer);
      this.loginPollTimer = -1;
    }
  }

  private runControlProbe(): void {
    try {
      this.controlProbeStatus = nativeBridge.controlProbe();
    } catch (error) {
      this.controlProbeStatus = `Control TLS Probe Failed: ${JSON.stringify(error)}`;
    }
  }

  private vpnWant(): Want {
    return {
      bundleName: 'io.github.tailscaleohos',
      abilityName: 'TailscaleVpnExtensionAbility'
    };
  }

  private beginVpnConnection(): void {
    if (this.connectInProgress || this.isConnecting()) {
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionStartedAtMs = Date.now();
    this.setConnectInProgress(true);
    // Let the button render its loading state before the native/VPN calls.
    setTimeout(() => this.startVpnProbe(), 300);
  }

  private startVpnProbe(): void {
    const backendConfig: string = nativeBridge.backendVpnConfig();
    if (backendConfig.startsWith('FAILED')) {
      this.vpnStatus = 'Sign in to Tailscale before connecting';
      this.clearConnectionCompletionTimer();
      this.setConnectInProgress(false);
      return;
    }
    const magicDNSProbeUrl: string = nativeBridge.backendMagicDNSProbeURL();
    if (magicDNSProbeUrl.startsWith('http://')) {
      this.magicDNSProbeUrl = magicDNSProbeUrl;
      this.magicDNSProbeStatus = 'MagicDNS identity-redacted probe ready';
    } else {
      this.magicDNSProbeUrl = '';
      this.magicDNSProbeStatus = magicDNSProbeUrl;
    }
    this.backendStatus = nativeBridge.backendStop();
    this.vpnStatus = 'Requesting HarmonyOS VPN authorization';
    vpnExtension.startVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.vpnStatus = 'HarmonyOS VPN Extension start requested';
        this.startConnectionPolling();
      })
      .catch((error: BusinessError) => {
        this.vpnStatus = `FAILED | VPN start | code=${error.code}`;
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      });
  }

  private runMagicDNSProbe(): void {
    if (!this.magicDNSProbeUrl.startsWith('http://')) {
      this.magicDNSProbeStatus = 'SKIPPED | MagicDNS probe | no in-memory target';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.magicDNSProbeStatus = 'Opening identity-redacted MagicDNS probe';
    context.openLink(this.magicDNSProbeUrl, { appLinkingOnly: false })
      .then(() => {
        this.magicDNSProbeStatus = 'MagicDNS browser probe opened';
      })
      .catch(() => {
        this.magicDNSProbeStatus = 'FAILED | MagicDNS browser probe';
      });
  }

  private stopVpnProbe(): void {
    this.clearConnectionCompletionTimer();
    this.setConnectInProgress(false);
    vpnExtension.stopVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.vpnStatus = 'HarmonyOS VPN Extension stopped';
        this.stopConnectionPolling();
        this.startBackend();
        setTimeout(() => this.refreshBackendStatus(), 1500);
      })
      .catch((error: BusinessError) => {
        this.vpnStatus = `FAILED | VPN stop | code=${error.code}`;
      });
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.logout_confirm_title'),
      message: $r('app.string.logout_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.logout_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.logout()
      }
    });
  }

  private logout(): void {
    try {
      this.logoutStatus = nativeBridge.backendLogout();
      if (!this.logoutStatus.startsWith('FAILED')) {
        this.loginInProgress = false;
        this.hasAuthenticatedSession = false;
        this.stopLoginPolling();
        this.peers = [];
        this.exitNodes = [];
        this.exitNodeStatus = '未使用出口节点';
        this.loginHandoffStatus = 'Secure Login Pending';
        setTimeout(() => this.refreshBackendStatus(), 500);
      }
    } catch (_error) {
      this.logoutStatus = 'FAILED | logout | unavailable';
    }
  }

  private refreshVpnProbeStatus(): boolean {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const statusPath: string = `${context.filesDir}/vpn-probe-status.txt`;
      if (!fileIo.accessSync(statusPath)) {
        this.vpnStatus = 'HarmonyOS VPN Extension Stopped';
        return false;
      }
      const persistedStatus: string = fileIo.readTextSync(statusPath);
      const heartbeatMatch: RegExpMatchArray | null = persistedStatus.match(/heartbeatMs=(\d+)/);
      const heartbeatMs: number = heartbeatMatch === null ? 0 : Number(heartbeatMatch[1]);
      const heartbeatAgeMs: number = Date.now() - heartbeatMs;
      const heartbeatIsFresh: boolean = heartbeatMs > 0 && heartbeatAgeMs >= 0 && heartbeatAgeMs <= 5000;
      const visibleStatus: string = persistedStatus.replace(/\s*\|\s*heartbeatMs=\d+/, '');
      const extensionIsLive: boolean = heartbeatIsFresh && !visibleStatus.includes('destroyed');
      if (visibleStatus.includes('state=Running') && this.connectInProgress) {
        const remainingMs: number = MIN_CONNECTION_LOADING_MS -
          (Date.now() - this.connectionStartedAtMs);
        if (remainingMs > 0) {
          if (this.connectionCompletionTimer < 0) {
            this.connectionCompletionTimer = setTimeout(() => {
              this.commitConnectedStatus(visibleStatus);
            }, remainingMs);
          }
          return extensionIsLive;
        }
      }
      this.vpnStatus = !extensionIsLive && visibleStatus.includes('tun=true') ?
        'HarmonyOS VPN Extension Stopped (previous session ended)' : visibleStatus;
      if (visibleStatus.includes('state=Running') || visibleStatus.startsWith('FAILED')) {
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      }
      return extensionIsLive;
    } catch (error) {
      const businessError = error as BusinessError;
      this.vpnStatus = `FAILED | VPN status file | code=${businessError.code}`;
      return false;
    }
  }

  private startConnectionPolling(): void {
    this.stopConnectionPolling();
    this.connectionPollTimer = setInterval(() => {
      this.refreshVpnProbeStatus();
      if (this.vpnStatus.includes('state=Running') || this.vpnStatus.startsWith('FAILED')) {
        this.stopConnectionPolling();
      }
    }, 1000);
  }

  private stopConnectionPolling(): void {
    if (this.connectionPollTimer >= 0) {
      clearInterval(this.connectionPollTimer);
      this.connectionPollTimer = -1;
    }
  }

  private clearConnectionCompletionTimer(): void {
    if (this.connectionCompletionTimer >= 0) {
      clearTimeout(this.connectionCompletionTimer);
      this.connectionCompletionTimer = -1;
    }
  }

  private commitConnectedStatus(status: string): void {
    this.clearConnectionCompletionTimer();
    // Commit both states in the same render transaction so the progress
    // indicator disappears on the frame where the connected panel appears.
    this.vpnStatus = status;
    this.setConnectInProgress(false);
    this.stopConnectionPolling();
  }

  private startHealthPolling(): void {
    this.stopHealthPolling();
    this.healthPollTimer = setInterval(() => {
      const vpnIsLive: boolean = this.refreshVpnProbeStatus();
      if (!vpnIsLive) {
        this.refreshBackendStatus();
      }
    }, 2000);
  }

  private stopHealthPolling(): void {
    if (this.healthPollTimer >= 0) {
      clearInterval(this.healthPollTimer);
      this.healthPollTimer = -1;
    }
  }

  private isConnected(): boolean {
    return this.vpnStatus.includes('state=Running');
  }

  private isConnecting(): boolean {
    return this.connectInProgress ||
      this.vpnStatus.includes('start requested') ||
      this.vpnStatus.includes('authorization') ||
      this.vpnStatus.includes('starting');
  }

  private needsLogin(): boolean {
    return this.backendStatus.includes('NeedsLogin') ||
      this.backendStatus.includes('loginURLReady=true');
  }

  private hasConnectionProblem(): boolean {
    return this.vpnStatus.startsWith('FAILED') || this.backendStatus.startsWith('FAILED');
  }

  private isAuthenticated(): boolean {
    return this.hasAuthenticatedSession;
  }

  private isBackendLoading(): boolean {
    return !this.backendReady && !this.hasConnectionProblem();
  }

  private setConnectInProgress(inProgress: boolean): void {
    // Loading state must enter the component tree synchronously. Animating the
    // surrounding panel is handled by its modifier; delaying this assignment
    // can otherwise let a fast native failure skip the progress frame.
    this.connectInProgress = inProgress;
  }

  private onlinePeerCount(): number {
    return this.peers.filter((peer: PeerSummary) => peer.online).length;
  }

  private peerDeviceIcon(deviceType: string): Resource {
    if (deviceType === 'tablet') {
      return $r('app.media.device_tablet');
    }
    if (deviceType === 'phone' || deviceType === 'foldable') {
      return $r('app.media.device_phone');
    }
    return $r('app.media.device_laptop');
  }

  private localDeviceIcon(): Resource {
    return this.peerDeviceIcon(deviceInfo.deviceType);
  }

  private nodeNameSlug(value: string): string {
    return value.split('.')[0]
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  private localDeviceName(): string {
    const sourceName: string = this.accountSummary.deviceName.length > 0 ?
      this.accountSummary.deviceName : this.deviceModel();
    let nodeName: string = this.nodeNameSlug(sourceName);
    const brandName: string = this.nodeNameSlug(deviceInfo.brand);
    if (brandName.length > 0 && nodeName.startsWith(`${brandName}-`)) {
      nodeName = nodeName.substring(brandName.length + 1);
    }
    return nodeName.length > 0 ? nodeName : sourceName;
  }

  private displayOsName(os: string): string {
    switch (os.trim().toLowerCase()) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'macos':
      case 'darwin':
        return 'macOS';
      case 'ios':
        return 'iOS';
      case 'chromeos':
        return 'ChromeOS';
      case 'freebsd':
        return 'FreeBSD';
      case 'harmonyos':
      case 'openharmony':
        return 'HarmonyOS';
      default:
        return os;
    }
  }

  private peerDeviceDescription(peer: PeerSummary): string {
    return peer.os.length > 0 ? this.displayOsName(peer.os) : peer.deviceModel;
  }

  private primaryTailscaleAddress(addresses: string[]): string {
    const ipv4Address: string | undefined = addresses.find((address: string) =>
      !address.includes(':'));
    if (ipv4Address !== undefined) {
      return ipv4Address;
    }
    return addresses.length > 0 ? addresses[0] : '';
  }

  private settingsStatusText(): string {
    return this.isConnected() ? this.vpnStatus : this.backendStatus;
  }

  private routeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('routeAll=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('routeAll=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private magicDNSSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('corpDNS=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('corpDNS=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeLANSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNodeLAN=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNodeLAN=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNode=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNode=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private connectionTitle(): ResourceStr {
    if (this.isBackendLoading()) {
      return $r('app.string.connection_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.connection_connected');
    }
    if (this.isConnecting()) {
      return $r('app.string.connection_connecting');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.string.connection_problem');
    }
    if (this.needsLogin()) {
      return $r('app.string.connection_login_required');
    }
    return $r('app.string.connection_disconnected');
  }

  private connectionDescription(): ResourceStr {
    if (this.isBackendLoading()) {
      return $r('app.string.description_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.description_connected');
    }
    if (this.isConnecting()) {
      return $r('app.string.description_connecting');
    }
    if (this.needsLogin()) {
      return $r('app.string.description_login_required');
    }
    if (this.hasConnectionProblem()) {
      if (this.backendStatus.includes('tls-error') || this.backendStatus.includes('x509')) {
        return $r('app.string.description_tls_problem');
      }
      if (this.backendStatus.includes('network-timeout') ||
        this.backendStatus.includes('connection-error') || this.backendStatus.includes('netUp=false')) {
        return $r('app.string.description_network_problem');
      }
      if (this.vpnStatus.includes('VPN start') || this.vpnStatus.includes('authorization')) {
        return $r('app.string.description_vpn_permission_problem');
      }
      if (this.vpnStatus.includes('status file')) {
        return $r('app.string.description_status_problem');
      }
      return $r('app.string.description_problem');
    }
    return $r('app.string.description_disconnected');
  }

  private connectionColor(): ResourceColor {
    if (this.isConnected()) {
      return $r('app.color.status_success');
    }
    if (this.isConnecting()) {
      return $r('app.color.status_warning');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.color.status_error');
    }
    return $r('app.color.status_neutral');
  }

  private glowFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/ui-glow-level-v2`;
  }

  private resetDiagnosticsMode(): void {
    this.diagnosticsUnlocked = false;
    this.diagnosticsExpanded = false;
    this.diagnosticsTapCount = 0;
    this.diagnosticsLastTapMs = 0;
  }

  private unlockDiagnostics(): void {
    this.diagnosticsUnlocked = true;
    this.diagnosticsExpanded = false;
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (_error) {
      // Toast is immediate feedback only; failure must not block the gesture.
    }
  }

  private onAppVersionTap(): void {
    if (this.diagnosticsUnlocked) {
      this.showToast('您已进入工程模式');
      return;
    }
    const nowMs: number = Date.now();
    if (nowMs - this.diagnosticsLastTapMs > 1500) {
      this.diagnosticsTapCount = 0;
    }
    this.diagnosticsLastTapMs = nowMs;
    this.diagnosticsTapCount += 1;
    if (this.diagnosticsTapCount >= 5) {
      this.diagnosticsTapCount = 0;
      this.unlockDiagnostics();
      this.showToast('您已进入工程模式');
      return;
    }
    const remainingCount: number = 5 - this.diagnosticsTapCount;
    this.showToast(`再点击${remainingCount}次即可进入工程诊断`);
  }

  private loadGlowLevel(): void {
    try {
      const path: string = this.glowFilePath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const level: number = Number(fileIo.readTextSync(path));
      if (level >= 0 && level <= 3) {
        this.glowLevel = level;
      }
    } catch (_error) {
      this.glowLevel = 3;
    }
  }

  private setGlowLevel(level: number): void {
    if (level < 0 || level > 3) {
      return;
    }
    this.glowLevel = level;
    try {
      const file = fileIo.openSync(this.glowFilePath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, level.toString());
      fileIo.closeSync(file);
    } catch (_error) {
      // Visual preferences are best-effort and never affect VPN behavior.
    }
  }

  private glowRadius(): number {
    return this.glowLevel === 0 ? 28 : (this.glowLevel === 1 ? 18 : 10);
  }

  private glowColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSurface(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private glowMaskColor(): ResourceColor {
    return $r('sys.color.background_primary');
  }

  private glowLightColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSaturation(): number {
    return this.glowLevel === 0 ? 1.38 : (this.glowLevel === 1 ? 1.2 : 1.05);
  }

  private glowBrightness(): number {
    return this.glowLevel === 0 ? 1.12 : (this.glowLevel === 1 ? 1.07 : 1.02);
  }

  private glowMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.glowLevel === 0) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.glowLevel === 1) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.glowLevel === 2) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  private glowLevelDescription(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite_description');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle_description');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth_description');
    }
    return $r('app.string.glow_adaptive_description');
  }

  private glowLevelLabel(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth');
    }
    return $r('app.string.glow_adaptive');
  }

  private isWideNavigation(): boolean {
    return this.layoutWidth >= 840;
  }

  private pageMargin(): number {
    if (this.layoutWidth >= 840) {
      return 32;
    }
    if (this.layoutWidth >= 600) {
      return 24;
    }
    return 16;
  }

  private contentMargin(): number {
    return this.pageMargin() + 8;
  }

  private pageBottomInset(): number {
    return this.isWideNavigation() ? 32 : 120;
  }

  private groupBackground(): ResourceColor {
    return $r('sys.color.comp_background_primary');
  }

  private isPeerNameExpanded(peerKey: string): boolean {
    return this.expandedPeerKeys.includes(peerKey);
  }

  private togglePeerName(peerKey: string): void {
    if (this.isPeerNameExpanded(peerKey)) {
      this.expandedPeerKeys = this.expandedPeerKeys.filter((key: string) => key !== peerKey);
      return;
    }
    this.expandedPeerKeys = this.expandedPeerKeys.concat(peerKey);
  }

  private secondaryBackground(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private accountInitial(): string {
    const source: string = this.accountSummary.displayName.length > 0 ?
      this.accountSummary.displayName : this.accountSummary.loginName;
    return source.length > 0 ? source.substring(0, 1).toUpperCase() : 'T';
  }

  @Builder
  private SectionHeader(title: ResourceStr, description?: ResourceStr) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (description !== undefined) {
        Text(description)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SettingsGroupHeader(title: ResourceStr) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ top: 12, bottom: 4 })
  }

  @Builder
  private ButtonContent(label: ResourceStr, primary: boolean, loading: boolean) {
    Row({ space: 8 }) {
      if (loading) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(primary ? $r('sys.color.font_on_primary') : $r('sys.color.icon_primary'))
      }
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  private ConnectButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_connect'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.connectInProgress || this.isConnecting() ? 0 : 1)
      if (this.connectInProgress || this.isConnecting()) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('vpn-start-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_connecting'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private LoginButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_login'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.loginInProgress ? 0 : 1)
      if (this.loginInProgress) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('login-open-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_login'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private ConnectButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.ConnectButtonContent()
    }
      .id('vpn-start')
      .width('100%')
      .height(52)
      .enabled(!this.connectInProgress && !this.isConnecting())
      .onClick(() => this.beginVpnConnection())
  }

  @Builder
  private LoginButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.LoginButtonContent()
    }
      .id('login-open')
      .width('100%')
      .height(52)
      .enabled(!this.loginInProgress)
      .onClick(() => this.openSecureLogin())
  }

  @Builder
  private ImmersiveButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    if (this.glowLevel === 3) {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    } else {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .backgroundEffect({
          radius: this.glowRadius(),
          saturation: this.glowSaturation(),
          brightness: this.glowBrightness(),
          color: primary ? $r('sys.color.comp_background_emphasize') : this.glowSurface(),
          adaptiveColor: AdaptiveColor.DEFAULT
        }, { disableSystemAdaptation: false })
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .shadow({
          radius: this.glowLevel === 0 ? 12 : (this.glowLevel === 1 ? 8 : 4),
          color: this.glowColor(),
          offsetY: 3
        })
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    }
  }

  @Builder
  private StandardActionButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      this.ButtonContent(label, primary, loading)
    }
      .id(nodeId)
      .width('100%')
      .height(52)
      .opacity(enabled ? 1 : 0.4)
      .enabled(enabled)
      .onClick(action)
  }

  @Builder
  private ConnectionPanel() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Stack() {
          Image($r('app.media.connection_filled'))
            .width(28)
            .height(28)
            .fillColor(this.connectionColor())
        }
        .width(48)
        .height(48)
        .borderRadius(16)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Text(this.connectionTitle())
            .id('smoke-title')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text(this.connectionDescription())
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      if (this.isConnected()) {
        this.StandardActionButton($r('app.string.action_disconnect'), 'vpn-stop', false, true,
          () => this.stopVpnProbe())
      } else if (this.isBackendLoading()) {
        this.StandardActionButton($r('app.string.action_starting'), 'backend-starting', true,
          false, () => {}, true)
      } else if (this.needsLogin()) {
        this.LoginButton()
      } else {
        this.ConnectButton()
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private NetworkSettingsPanel() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_subnet_routes'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_subnet_routes_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.routeAll })
          .id('route-all-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('routeAll', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ top: 8, bottom: 8 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_magicdns'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_magicdns_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.corpDNS })
          .id('tailscale-dns-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('corpDNS', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ top: 8, bottom: 8 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_exit_node_lan'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_exit_node_lan_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.exitNodeAllowLANAccess })
          .id('exit-node-lan-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) =>
            this.setNetworkSetting('exitNodeAllowLANAccess', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 72 })
      .padding({ top: 8, bottom: 8 })

      if (this.networkSettingStatus.startsWith('FAILED')) {
        Text($r('app.string.network_setting_failed'))
          .id('network-setting-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
          .padding({ top: 8 })
      }
    }
    .id('network-settings-panel')
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private ExitNodeChoiceButton(label: ResourceStr, nodeId: string, selected: boolean,
    enabled: boolean, action: () => void) {
    Button() {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(enabled ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_emphasize')])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .id(nodeId)
    .width('100%')
    .height(52)
    .type(ButtonType.Normal)
    .borderRadius(20)
    .backgroundColor(selected ? '#14126BFF' : this.secondaryBackground())
    .backgroundEffect({
      radius: this.glowRadius(),
      saturation: this.glowSaturation(),
      brightness: this.glowBrightness(),
      color: this.glowSurface(),
      adaptiveColor: AdaptiveColor.DEFAULT
    }, { disableSystemAdaptation: false })
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
      .buildEffect())
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.45)
    .stateEffect(true)
    .onClick(action)
  }

  @Builder
  private ExitNodePanel() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.exit_node_title'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.exit_node_description'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.exitNodeStatus)
          .id('exit-node-status')
          .fontSize(13)
          .fontColor(this.exitNodeStatus.startsWith('FAILED') ?
            $r('app.color.status_error') : $r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (!this.isAuthenticated()) {
        Text($r('app.string.exit_node_login_required'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      } else if (this.exitNodes.length === 0) {
        Text($r('app.string.exit_node_empty'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      } else {
        this.ExitNodeChoiceButton($r('app.string.exit_node_none'), 'exit-node-none',
          !this.exitNodes.some((choice: ExitNodeChoice) => choice.selected),
          !this.isConnected() && !this.isConnecting() && !this.connectInProgress,
          () => this.setExitNode(''))
        ForEach(this.exitNodes, (choice: ExitNodeChoice) => {
          this.ExitNodeChoiceButton(choice.name, 'exit-node-' + choice.id, choice.selected,
            choice.online && !this.isConnected() && !this.isConnecting() && !this.connectInProgress,
            () => this.setExitNode(choice.id))
        }, (choice: ExitNodeChoice) => choice.id)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private DevicesLoadingPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), $r('app.string.action_starting'))
      Column({ space: 10 }) {
        LoadingProgress()
          .id('devices-loading')
          .width(28)
          .height(28)
          .color($r('sys.color.icon_emphasize'))
        Text($r('app.string.action_starting'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DevicesSignedOutPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), '')
      Column() {
        Text($r('app.string.account_profile_unavailable'))
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private LocalDeviceRow() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.localDeviceIcon())
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.connectionColor())
      }
      .width(36)
      .height(36)
      .padding(7)
      .borderRadius(11)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 1 }) {
        Row({ space: 6 }) {
          Text(this.localDeviceName())
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .layoutWeight(1)
          Text($r('app.string.local_device_badge'))
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(7)
            .backgroundColor(this.secondaryBackground())
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        Row({ space: 5 }) {
          Text(this.connectionTitle())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Text('· HarmonyOS')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        if (this.accountSummary.addresses.length > 0) {
          Text(this.primaryTailscaleAddress(this.accountSummary.addresses))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ top: 6, right: 12, bottom: 6 })
  }

  @Builder
  private PeerDeviceRow(peer: PeerSummary) {
    Column({ space: 0 }) {
      Divider().color($r('sys.color.comp_divider'))
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(22)
            .height(22)
            .fillColor($r('sys.color.icon_primary'))
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .border({ width: 2, color: this.groupBackground() })
            .backgroundColor(peer.online ? $r('app.color.status_success') :
              $r('app.color.status_offline'))
        }
        .width(36)
        .height(36)
        .padding(7)
        .borderRadius(11)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 1 }) {
          Text(peer.name)
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(this.isPeerNameExpanded(peer.key) ? 6 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
            .onClick(() => this.togglePeerName(peer.key))
          Row({ space: 5 }) {
            Text(peer.online ? $r('app.string.peer_online') : $r('app.string.peer_offline'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            if (this.peerDeviceDescription(peer).length > 0) {
              Text('· ' + this.peerDeviceDescription(peer))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            if (peer.exitNode) {
              Text($r('app.string.peer_exit_node'))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
          .width('100%')
          if (peer.addresses.length > 0) {
            Text(this.primaryTailscaleAddress(peer.addresses))
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ top: 6, right: 12, bottom: 6 })
    }
    .width('100%')
  }

  @Builder
  private DevicesPanel() {
    Column({ space: 0 }) {
      this.SectionHeader($r('app.string.devices_title'),
        $r('app.string.devices_count', this.onlinePeerCount() + (this.isConnected() ? 1 : 0),
          this.peers.length + 1))
      Text('')
        .id('peer-summary')
        .height(4)
        .fontSize(1)
        .accessibilityLevel('no')
      List() {
        ListItem() {
          this.LocalDeviceRow()
        }
        ForEach(this.peers, (peer: PeerSummary) => {
          ListItem() {
            this.PeerDeviceRow(peer)
          }
        }, (peer: PeerSummary) => peer.key)
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(this.peers.length + 1 > 3 ? BarState.Auto : BarState.Off)
      .scrollBarWidth(3)
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding({ left: 16, right: 4, top: 14, bottom: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private GlowSettingsPanel() {
    Row({ space: 12 }) {
      Text($r('app.string.glow_title'))
        .id('settings-page-title')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Select([
        { value: $r('app.string.glow_exquisite') },
        { value: $r('app.string.glow_gentle') },
        { value: $r('app.string.glow_smooth') },
        { value: $r('app.string.glow_adaptive') }
      ])
        .id('glow-select')
        .selected(this.glowLevel)
        .value(this.glowLevelLabel())
        .controlSize(ControlSize.NORMAL)
        .constraintSize({ minWidth: 112, maxWidth: 160 })
        .onSelect((index: number, _value?: string) => this.setGlowLevel(index))
    }
    .id('glow-settings')
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private AccountPanel() {
    Column({ space: 10 }) {
      if (!this.isAuthenticated()) {
        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.tab_home'))
              .width(28)
              .height(28)
              .fillColor($r('sys.color.icon_secondary'))
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.secondaryBackground())
          Text($r('app.string.account_profile_unavailable'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        this.StandardActionButton($r('app.string.action_login'), 'account-login', true,
          !this.loginInProgress, () => this.openSecureLogin(), this.loginInProgress)
      } else {
        Row({ space: 12 }) {
          Stack() {
            if (this.accountSummary.profilePicURL.length > 0 && !this.avatarLoadFailed) {
              Image(this.accountSummary.profilePicURL)
                .id('account-avatar')
                .width(56)
                .height(56)
                .borderRadius(28)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.avatarLoadFailed = true;
                })
            } else {
              Text(this.accountInitial())
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_emphasize'))
            }
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.secondaryBackground())

          Column({ space: 2 }) {
            Text(this.accountSummary.displayName)
              .id('account-display-name')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.accountSummary.loginName)
              .id('account-login-name')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        Divider().color($r('sys.color.comp_divider'))
        this.AccountDetailRow($r('app.string.account_tailnet'),
          this.accountSummary.tailnetName, 'account-tailnet')
        this.AccountDetailRow($r('app.string.account_device'),
          this.accountSummary.deviceName, 'account-device')

        if (!this.isConnected()) {
          Text($r('app.string.logout_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Button($r('app.string.logout_action'), {
            type: ButtonType.ROUNDED_RECTANGLE,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.NORMAL,
            controlSize: ControlSize.NORMAL,
            role: ButtonRole.ERROR
          })
            .id('logout-open')
            .width('100%')
            .visualEffect(new hdsEffect.HdsEffectBuilder()
              .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
              .buildEffect())
            .onClick(() => this.confirmLogout())
        }
      }

      if (this.logoutStatus.startsWith('FAILED')) {
        Text($r('app.string.logout_failed'))
          .id('logout-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private AccountDetailRow(label: ResourceStr, value: string, nodeId: string,
    action?: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(value.length > 0 ? value : '—')
        .id(nodeId)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .onClick(() => {
      if (action !== undefined) {
        action();
      }
    })
  }

  @Builder
  private AppVersionActionRow() {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.NORMAL
    }) {
      Row({ space: 12 }) {
        Text($r('app.string.app_version_label'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Text('0.2.19-beta.6')
          .id('app-version')
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .id('app-version-action')
    .width('100%')
    .height(44)
    .padding(0)
    .borderRadius(12)
    .onClick(() => this.onAppVersionTap())
  }

  @Builder
  private VersionPanel() {
    Column({ space: 0 }) {
      this.AppVersionActionRow()
      this.AccountDetailRow($r('app.string.tailscale_version_label'),
        this.tailscaleVersion, 'tailscale-version')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DiagnosticStatus(title: ResourceStr | string, value: string, nodeId: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(value)
        .id(nodeId)
        .fontSize(13)
        .fontColor(value.startsWith('FAILED') ?
          $r('app.color.status_error') : $r('sys.color.font_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  private DiagnosticsPanel() {
    Column({ space: 8 }) {
      this.DiagnosticStatus('Go Bridge', this.nativeStatus, 'smoke-go-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Tailscale Engine', this.engineStatus, 'engine-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Control Plane', this.backendStatus, 'backend-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('VPN Extension', this.vpnStatus, 'vpn-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('MagicDNS', this.magicDNSProbeStatus, 'magicdns-status')

      this.StandardActionButton('Refresh status', 'backend-refresh', false, true, () => {
        this.verifyNativeBridge();
        this.refreshBackendStatus();
        this.refreshVpnProbeStatus();
      })
      this.StandardActionButton('Probe engine', 'engine-probe', false, true,
        () => this.probeUserspaceEngine())
      this.StandardActionButton('Probe control TLS', 'control-probe', false, true,
        () => this.runControlProbe())
      this.StandardActionButton('Open MagicDNS probe', 'magicdns-probe', false,
        this.magicDNSProbeUrl.startsWith('http://'), () => this.runMagicDNSProbe())
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder
  private DiagnosticsDisclosure() {
    Column({ space: 0 }) {
      Button({
        type: ButtonType.Normal,
        stateEffect: true,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        controlSize: ControlSize.NORMAL
      }) {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text($r('app.string.diagnostics_title'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
            Text($r('app.string.diagnostics_description'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(20)
            .fontColor([$r('sys.color.icon_secondary')])
            .rotate({ angle: this.diagnosticsExpanded ? 180 : 0 })
            .animation({ duration: 220, curve: Curve.EaseInOut })
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      }
      .id('diagnostics-disclosure')
      .width('100%')
      .height(64)
      .borderRadius(12)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.diagnosticsExpanded = !this.diagnosticsExpanded;
        });
      })

      if (this.diagnosticsExpanded) {
        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 16, right: 16 })
        this.DiagnosticsPanel()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .margin({ top: 16 })
  }

  @Builder
  private HomeContent() {
    Column({ space: 12 }) {
      this.ConnectionPanel()
      this.ExitNodePanel()
      if (this.isBackendLoading() || this.devicesLoading) {
        this.DevicesLoadingPanel()
      } else if (!this.isAuthenticated()) {
        this.DevicesSignedOutPanel()
      } else {
        this.DevicesPanel()
      }
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: 1200 })
    .padding({
      left: this.contentMargin(),
      right: this.contentMargin(),
      top: 8,
      bottom: this.pageBottomInset()
    })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsContent() {
    Scroll(this.settingsScroller) {
      Column() {
        GridRow({
          columns: { xs: 2, sm: 4, md: 8, lg: 12 },
          gutter: { x: 12, y: 8 }
        }) {
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.account_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.AccountPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.NetworkSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_appearance_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.GlowSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.about_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.VersionPanel()
          }
          if (this.diagnosticsUnlocked) {
            GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
              this.DiagnosticsDisclosure()
            }
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 1200 })
      }
      .width('100%')
      .padding({
        left: this.contentMargin(),
        right: this.contentMargin(),
        top: 8,
        bottom: this.pageBottomInset()
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
  }

  @Builder
  private HomePage() {
    HdsNavigation() {
      this.HomeContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.app_title'),
          subTitle: $r('app.string.app_tagline')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsPage() {
    HdsNavigation() {
      this.SettingsContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.tab_settings'),
          subTitle: $r('app.string.settings_subtitle')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FREE)
    .bindToScrollable([this.settingsScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private MobileTabs() {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_home'), $r('app.string.tab_home'))
        .id('tab-home')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))
    }
    .vertical(false)
    .scrollable(true)
    .animationDuration(320)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 40,
      gradientMask: {
        maskColor: $r('sys.color.background_secondary'),
        maskHeight: 48
      },
      lightColor: this.glowLightColor(),
      barOpacity: 0.96,
      thermoCtrl: true,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: this.glowMaterialLevel()
      }
    })
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  private WideTabs() {
    HdsTabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_home'), $r('app.string.tab_home'))
        .id('tab-home')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))
    }
    .vertical(true)
    .scrollable(false)
    .animationDuration(280)
    .barMode(BarMode.Fixed)
    .barWidth(96)
    .barOverlap(false)
    .barBackgroundColor($r('sys.color.comp_background_primary'))
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isWideNavigation()) {
        this.WideTabs()
      } else {
        this.MobileTabs()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.layoutWidth = Number(newValue.width);
    })
  }
}
