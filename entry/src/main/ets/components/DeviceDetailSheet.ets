import { UiTokens } from './UiTokens';
import { LightAppearance } from './LightAppearance';
import { PeerPathResult } from '../services/StreamingModels';
import { FeatureSetupDialog } from './FeatureSetupGuide';

interface StatusCapsuleData {
  label: ResourceStr;
  state: string;
}

interface ServiceStatusRowData {
  title: ResourceStr;
  label: ResourceStr;
  state: string;
  helpSection?: string;
}

@Component
export struct DeviceDetailSheet {
  @Env(WritableEnvKey.FONT_SCALE) private detailFontScale: number;
  @Prop online: boolean = false;
  @Prop meshConnected: boolean = false;
  @Prop path: PeerPathResult = { type: 'unknown', checkedAt: 0 };
  @Prop tailscaleAddress: string = '';
  @Prop magicDnsName: string = '';
  @Prop exitNodeCapable: boolean = false;
  @Prop servicesChecking: boolean = false;
  @Prop showSunshine: boolean = false;
  @Prop sunshineState: string = 'unknown';
  @Prop sunshineAvailable: boolean = false;
  @Prop sunshineLaunching: boolean = false;
  @Prop mediaServiceCount: number = 0;
  @Prop mediaProbeState: string = 'unknown';
  @Prop setupHelpEnabled: boolean = false;
  @Prop glowLevel: number = 3;
  @State private setupGuideVisible: boolean = false;
  @State private setupGuideSection: string = '';
  @State private setupGuidePresentation: number = 0;
  private setupGuideController?: CustomDialogController;
  @Prop mediaServiceNames: string = '';
  @Prop mediaLaunching: boolean = false;
  @Prop serviceRefreshVisible: boolean = false;
  @Prop localSendState: string = 'unknown';
  @Prop localSendRefreshing: boolean = false;
  @Prop localSendAvailable: boolean = false;
  @Prop taildropAvailable: boolean = false;
  @Prop taildropOnline: boolean = false;
  @Prop taildropReady: boolean = false;
  @Prop remoteFilesEnabled: boolean = false;
  onRefresh: () => Promise<void> = async (): Promise<void> => {};
  onOpenStream: () => void = () => {};
  onOpenMedia: () => void = () => {};
  onOpenFileTransfer: () => void = () => {};
  onOpenRemoteFiles: () => void = () => {};
  onCopyIp: () => void = () => {};
  onCopyDns: () => void = () => {};

  private canShowServiceHelp(): boolean {
    return this.setupHelpEnabled && this.online && this.meshConnected && !this.servicesRefreshing() &&
      !this.sunshineLaunching && !this.mediaLaunching;
  }

  private useLargeTextLayout(): boolean {
    return this.detailFontScale >= 1.5;
  }

  @Builder
  private ServiceSetupAction(title: Resource, section: string) {
    Button({ type: ButtonType.Circle, stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.SMALL }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(18).fontColor([$r('app.color.emphasize')])
    }
      .width(44).height(28)
      .responseRegion({ x: 0, y: -8, width: 44, height: 44 })
      .padding({ left: 12, right: 0 })
      .accessibilityText(title)
      .id('device-setup-help-' + section)
      .onClick(() => {
        if (this.canShowServiceHelp() && !this.setupGuideVisible) {
          this.setupGuideSection = section;
          this.setupGuidePresentation++;
          this.setupGuideVisible = true;
          this.setupGuideController = new CustomDialogController({
            builder: FeatureSetupDialog({ initialSection: this.setupGuideSection,
              presentationId: this.setupGuidePresentation }),
            alignment: DialogAlignment.Center,
            height: '70%',
            autoCancel: true,
            systemMaterial: LightAppearance.dialog(this.glowLevel),
            onDidDisappear: () => { this.setupGuideVisible = false; }
          });
          this.setupGuideController.open();
        }
      })
  }

  aboutToDisappear(): void {
    this.setupGuideController?.close();
    this.setupGuideController = undefined;
    this.setupGuideVisible = false;
  }

  private sunshineLabel(): ResourceStr {
    return this.probeStatusLabel(this.sunshineStatusState());
  }

  private sunshineStatusState(): string {
    return this.probeStatusState(this.sunshineState);
  }

  private localSendLabel(): ResourceStr {
    return this.probeStatusLabel(this.localSendStatusState());
  }

  private localSendStatusState(): string {
    return this.probeStatusState(this.localSendState, this.localSendAvailable);
  }

  private taildropLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    return this.taildropReady ? $r('app.string.device_detail_service_available') :
      $r('app.string.device_detail_service_unavailable');
  }

  private taildropStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.taildropReady ? 'available' : 'unavailable';
  }

  private mediaLabel(): ResourceStr {
    const state: string = this.mediaStatusState();
    return state === 'available' ?
      $r('app.string.device_detail_media_discovered', this.mediaServiceNames) : this.probeStatusLabel(state);
  }

  private mediaStatusState(): string {
    const state: string = this.mediaProbeState === 'available' && this.mediaServiceCount === 0 ?
      'unavailable' : this.mediaProbeState;
    return this.probeStatusState(state, this.mediaServiceCount > 0);
  }

  private probeStatusState(state: string, available: boolean = false): string {
    if (!this.online) return 'offline';
    if (!this.meshConnected) return 'disconnected';
    if (this.servicesRefreshing() || state === 'checking') return 'checking';
    if (available || state === 'available') return 'available';
    if (state === 'unavailable' || state === 'timeout' || state === 'error') return state;
    return 'unknown';
  }

  private probeStatusLabel(state: string): ResourceStr {
    switch (state) {
      case 'offline': return $r('app.string.device_detail_device_offline');
      case 'disconnected': return $r('app.string.connection_disconnected');
      case 'checking': return $r('app.string.transfer_protocol_refreshing');
      case 'available': return $r('app.string.device_detail_service_available');
      case 'unavailable': return $r('app.string.device_detail_service_unavailable');
      case 'timeout': return $r('app.string.device_detail_service_timeout');
      case 'error': return $r('app.string.device_detail_service_error');
      default: return $r('app.string.device_status_unknown');
    }
  }

  private taildriveLabel(): ResourceStr {
    if (!this.online) {
      return $r('app.string.device_detail_device_offline');
    }
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (this.servicesRefreshing()) {
      return $r('app.string.transfer_protocol_refreshing');
    }
    return this.remoteFilesEnabled ? $r('app.string.device_detail_service_available') :
      $r('app.string.device_detail_service_unavailable');
  }

  private taildriveStatusState(): string {
    if (!this.online) {
      return 'offline';
    }
    if (!this.meshConnected) {
      return 'disconnected';
    }
    if (this.servicesRefreshing()) {
      return 'checking';
    }
    return this.remoteFilesEnabled ? 'available' : 'unavailable';
  }

  private servicesRefreshing(): boolean {
    // The sheet that renders the spinner and capsules owns their visible state.
    // Parent polling and background probes cannot toggle it asynchronously.
    return this.serviceRefreshVisible;
  }

  private hasFileTransferAction(): boolean {
    return this.taildropReady || this.localSendAvailable;
  }

  private hasServiceActions(): boolean {
    if (!this.meshConnected) {
      return false;
    }
    return this.sunshineAvailable || this.mediaServiceCount > 0 || this.hasFileTransferAction() ||
      (this.online && this.remoteFilesEnabled);
  }

  private async refreshServices(): Promise<void> {
    if (!this.meshConnected || !this.online || this.servicesRefreshing()) {
      return;
    }
    try {
      await this.onRefresh();
    } catch (_error) {
      // A failed service must not leave the unified sheet state latched.
    }
  }

  private pathLabel(): ResourceStr {
    if (!this.meshConnected) {
      return $r('app.string.connection_disconnected');
    }
    if (!this.online) {
      return $r('app.string.peer_offline');
    }
    if (this.path.type === 'direct') {
      return $r('app.string.device_path_direct', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'peerRelay') {
      return $r('app.string.device_path_peer_relay', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'derp') {
      return $r('app.string.device_path_derp_relay', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'unreachable') {
      return $r('app.string.device_path_unreachable');
    }
    return $r('app.string.device_status_unknown');
  }

  @Builder
  private SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(UiTokens.SECTION_TITLE_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ left: 4, top: 4, bottom: 0 })
  }

  @Builder
  private StatusCapsule($$: StatusCapsuleData) {
    Stack({ alignContent: Alignment.End }) {
      Text($$.label)
        .fontSize(UiTokens.BADGE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor($$.state === 'available' ? $r('app.color.status_success') :
          ($$.state === 'checking' || $$.state === 'timeout' || $$.state === 'error') ? $r('app.color.status_warning') :
            $r('sys.color.font_secondary'))
        .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
          top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
        .backgroundColor($$.state === 'available' ? $r('app.color.badge_background_available') :
          ($$.state === 'checking' || $$.state === 'timeout' || $$.state === 'error') ?
            $r('app.color.badge_background_warning') : $r('app.color.badge_background_pending'))
        .borderRadius(UiTokens.BADGE_RADIUS)
        .wordBreak(WordBreak.BREAK_ALL)
        .constraintSize({ maxWidth: this.useLargeTextLayout() ? '100%' : 160 })
    }
    // Reserve a trailing column without stretching the colored text capsule.
    .width(this.useLargeTextLayout() ? '100%' : 52)
    .constraintSize({ minHeight: 28 })
    .align(Alignment.End)
  }

  @Builder
  private ServiceStatusRow($$: ServiceStatusRowData) {
    if (this.useLargeTextLayout()) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text($$.title)
            .fontSize(UiTokens.BODY_SIZE)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          if (this.canShowServiceHelp() && $$.helpSection) {
            this.ServiceSetupAction($$.helpSection === 'streaming' ?
              $r('app.string.feature_guide_streaming_help') : $r('app.string.feature_guide_media_help'),
              $$.helpSection ?? '')
          }
        }
        .width('100%')
        this.StatusCapsule({ label: $$.label, state: $$.state })
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 8, bottom: 8 })
    } else {
      Row({ space: 0 }) {
        Text($$.title)
          .fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .wordBreak(WordBreak.BREAK_ALL)
        if (this.canShowServiceHelp() && $$.helpSection) {
          this.ServiceSetupAction($$.helpSection === 'streaming' ?
            $r('app.string.feature_guide_streaming_help') : $r('app.string.feature_guide_media_help'),
            $$.helpSection ?? '')
        }
        this.StatusCapsule({ label: $$.label, state: $$.state })
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 8, bottom: 8 })
    }
  }

  @Builder
  private CompactAction(icon: Resource, title: ResourceStr, loading: boolean, action: () => void) {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      Row({ space: 5 }) {
        if (loading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.emphasize'))
        } else {
          SymbolGlyph(icon)
            .fontSize(18)
            .fontColor([$r('app.color.emphasize')])
        }
        Text(title)
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .layoutWeight(this.useLargeTextLayout() ? 0 : 1)
    .width(this.useLargeTextLayout() ? '100%' : undefined)
    .constraintSize({ minHeight: 54 })
    .border({ width: 0.5, color: $r('sys.color.comp_divider'), radius: 10 })
    .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    .enabled(!loading)
    .opacity(loading ? 0.58 : 1)
    .onClick(() => {
      if (!loading) {
        action();
      }
    })
  }

  @Builder
  private NetworkInfoContent(label: ResourceStr, value: ResourceStr, copy: boolean, actionable: boolean) {
    Flex({ direction: this.useLargeTextLayout() ? FlexDirection.Column : FlexDirection.Row,
      alignItems: ItemAlign.Center }) {
      Text(label)
        .fontSize(UiTokens.BODY_SIZE)
        .fontColor($r('sys.color.font_secondary'))
        .width(this.useLargeTextLayout() ? '100%' : undefined)
        .margin({ right: this.useLargeTextLayout() ? 0 : 12, bottom: this.useLargeTextLayout() ? 4 : 0 })
      Row({ space: 12 }) {
        Text(value)
          .fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .wordBreak(WordBreak.BREAK_ALL)
          .textAlign(TextAlign.End)
        if (copy || actionable) {
          SymbolGlyph(copy ? $r('sys.symbol.square_on_square_fill') : $r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
        }
      }
      .layoutWeight(this.useLargeTextLayout() ? 0 : 1)
      .width(this.useLargeTextLayout() ? '100%' : undefined)
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 8, bottom: 8 })
  }

  @Builder
  private InfoRow(label: ResourceStr, value: ResourceStr, actionable: boolean,
    action: () => void = () => {}) {
    Column() {
      this.NetworkInfoContent(label, value, false, actionable)
    }
    .width('100%')
    .onClick(() => {
      if (actionable) {
        action();
      }
    })
  }

  @Builder
  private CopyInfoRow(label: ResourceStr, value: string, action: () => void,
    rowId: string = 'device-detail-copy-ip', copyLabel: Resource = $r('app.string.peer_copy_ip')) {
    Column() {
      this.NetworkInfoContent(label, value, true, false)
    }
    .width('100%')
    .id(rowId)
    .accessibilityGroup(true)
    .accessibilityText(copyLabel)
    .accessibilityDescription(value)
    .onClick(action)
  }

  build() {
    Scroll() {
      Column({ space: UiTokens.GROUP_GAP }) {
        Row() {
          Text($r('app.string.device_detail_services_title'))
            .fontSize(UiTokens.SECTION_TITLE_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .padding({ left: 4, top: 4, bottom: 0 })
          Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            if (this.servicesRefreshing()) {
              LoadingProgress()
                .width(17)
                .height(17)
                .color($r('sys.color.icon_secondary'))
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(17)
                .fontColor([$r('sys.color.icon_secondary')])
            }
          }
          .width(44)
          .height(44)
          .enabled(this.meshConnected && this.online && !this.servicesRefreshing())
          .opacity(this.meshConnected && this.online ? 1 : 0.45)
          .accessibilityText($r('app.string.device_detail_refresh_services'))
          .onClick(() => this.refreshServices())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column({ space: 0 }) {
          if (this.showSunshine) {
            this.ServiceStatusRow({ title: 'Sunshine', label: this.sunshineLabel(), state: this.sunshineStatusState(),
              helpSection: this.sunshineState === 'available' || this.sunshineState === 'unavailable' ? 'streaming' : '' })
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          }
          this.ServiceStatusRow({ title: $r('app.string.media_services_label'), label: this.mediaLabel(),
            state: this.mediaStatusState(),
            helpSection: this.mediaProbeState === 'available' || this.mediaProbeState === 'unavailable' ? 'media' : '' })
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.ServiceStatusRow({ title: 'Taildrop', label: this.taildropLabel(), state: this.taildropStatusState() })
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.ServiceStatusRow({ title: 'LocalSend', label: this.localSendLabel(), state: this.localSendStatusState() })
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.ServiceStatusRow({ title: 'Taildrive', label: this.taildriveLabel(), state: this.taildriveStatusState() })

          if (this.hasServiceActions()) {
            Divider()
              .color($r('sys.color.comp_divider'))
            Column({ space: 6 }) {
              if (this.useLargeTextLayout()) {
                if (this.sunshineAvailable) {
                  this.CompactAction($r('sys.symbol.rectangle_on_rectangle'),
                    $r('app.string.device_detail_remote_desktop_title'), this.sunshineLaunching,
                    this.onOpenStream)
                }
                if (this.mediaServiceCount > 0) {
                  this.CompactAction($r('sys.symbol.video'),
                    $r('app.string.device_detail_media_title'), this.mediaLaunching,
                    this.onOpenMedia)
                }
                if (this.hasFileTransferAction()) {
                  this.CompactAction($r('sys.symbol.doc'),
                    $r('app.string.device_detail_transfer_title'), false,
                    this.onOpenFileTransfer)
                }
                if (this.online && this.remoteFilesEnabled) {
                  this.CompactAction($r('sys.symbol.folder'),
                    $r('app.string.device_detail_remote_files_title'), false,
                    this.onOpenRemoteFiles)
                }
              } else {
                Row({ space: 6 }) {
                  if (this.sunshineAvailable) {
                    this.CompactAction($r('sys.symbol.rectangle_on_rectangle'),
                      $r('app.string.device_detail_remote_desktop_title'), this.sunshineLaunching,
                      this.onOpenStream)
                  }
                  if (this.mediaServiceCount > 0) {
                    this.CompactAction($r('sys.symbol.video'),
                      $r('app.string.device_detail_media_title'), this.mediaLaunching,
                      this.onOpenMedia)
                  }
                }
                .width('100%')

                Row({ space: 6 }) {
                  if (this.hasFileTransferAction()) {
                    this.CompactAction($r('sys.symbol.doc'),
                      $r('app.string.device_detail_transfer_title'), false,
                      this.onOpenFileTransfer)
                  }
                  if (this.online && this.remoteFilesEnabled) {
                    this.CompactAction($r('sys.symbol.folder'),
                      $r('app.string.device_detail_remote_files_title'), false,
                      this.onOpenRemoteFiles)
                  }
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(6)
          }
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)

        this.SectionTitle($r('app.string.device_detail_network_title'))
        Column({ space: 0 }) {
          this.InfoRow($r('app.string.device_connection_path'), this.pathLabel(), false)
          if (this.tailscaleAddress.length > 0) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
            this.CopyInfoRow($r('app.string.network_sheet_local_address'), this.tailscaleAddress,
              this.onCopyIp)
          }
          if (this.magicDnsName.length > 0) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
            this.CopyInfoRow('MagicDNS', this.magicDnsName, this.onCopyDns,
              'device-detail-copy-dns', $r('app.string.peer_copy_dns'))
          }
          if (this.exitNodeCapable) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
            this.InfoRow($r('app.string.exit_node_title'),
              $r('app.string.device_detail_exit_node_available'), false)
          }
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)

        Blank()
          .width('100%')
          .height(16)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 4, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .nestedScroll({
      // Keep the half-modal detent/title fixed while the detail page scrolls.
      // The sheet can still take over once the content reaches its edge.
      scrollForward: NestedScrollMode.SELF_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .align(Alignment.TopStart)
    .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
  }
}
