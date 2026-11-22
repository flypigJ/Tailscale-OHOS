import { ExperimentalBackgroundMode, ExperimentalBackgroundService } from '../services/ExperimentalBackgroundService';
import { LightAppearance } from './LightAppearance';
import { ResponsiveLayout } from './ResponsiveLayout';
import { UiTokens } from './UiTokens';

interface BackgroundModeRowData {
  mode: ExperimentalBackgroundMode;
  title: Resource;
  detail: ResourceStr;
  icon: Resource;
  isOn: boolean;
  busy: boolean;
  glowLevel: number;
}

@Component
export struct BackgroundRunningSettings {
  contentScroller: Scroller = new Scroller();
  @Prop contentMargin: number = 16;
  @Prop bottomInset: number = 120;
  @Prop glowLevel: number = 3;
  @Prop canvasBackground: ResourceColor = $r('sys.color.background_secondary');
  @Prop groupBackground: ResourceColor = $r('sys.color.comp_background_primary');
  @State locationEnabled: boolean = false;
  @State pipEnabled: boolean = false;
  @State audioEnabled: boolean = false;
  @State downloadEnabled: boolean = false;
  @State busy: boolean = false;
  @State errorCode: number = 0;
  private service: ExperimentalBackgroundService = ExperimentalBackgroundService.instance();
  private changed: () => void = () => this.refresh();

  aboutToAppear(): void {
    this.service.subscribe(this.changed);
    this.refresh();
  }

  aboutToDisappear(): void { this.service.unsubscribe(this.changed); }

  private modeEnabled(mode: ExperimentalBackgroundMode): boolean {
    if (mode === 'location') return this.locationEnabled;
    if (mode === 'pip') return this.pipEnabled;
    if (mode === 'audio') return this.audioEnabled;
    return this.downloadEnabled;
  }

  private setModeEnabled(mode: ExperimentalBackgroundMode, value: boolean): void {
    if (mode === 'location') this.locationEnabled = value;
    else if (mode === 'pip') this.pipEnabled = value;
    else if (mode === 'audio') this.audioEnabled = value;
    else this.downloadEnabled = value;
  }

  private onToggleChange(mode: ExperimentalBackgroundMode, value: boolean): void {
    if (this.busy || value === this.modeEnabled(mode) || value === this.service.isActive(mode)) return;
    void this.change(mode, value);
  }

  private refresh(): void {
    this.locationEnabled = this.service.isActive('location');
    this.pipEnabled = this.service.isActive('pip');
    this.audioEnabled = this.service.isActive('audio');
    this.downloadEnabled = this.service.isActive('download');
    this.errorCode = this.service.lastError();
  }

  private async change(mode: ExperimentalBackgroundMode, enabled: boolean): Promise<void> {
    if (this.busy || enabled === this.service.isActive(mode)) {
      this.refresh();
      return;
    }
    this.setModeEnabled(mode, enabled);
    this.busy = true;
    try {
      await this.service.setEnabled(mode, enabled, this.getUIContext());
    } finally {
      this.refresh();
      this.busy = false;
    }
  }

  @Builder
  private ModeRow($$: BackgroundModeRowData) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($$.icon)
          .fontSize(UiTokens.ICON_LIST_LEADING)
          .fontColor([$r('app.color.emphasize')])
      }
      .width(UiTokens.ICON_LIST_CONTAINER)
      .height(UiTokens.ICON_LIST_CONTAINER)
      .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      Column({ space: 4 }) {
        Text($$.title)
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text($$.detail)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: $$.isOn })
        .enabled(!$$.busy)
        .selectedColor($r('app.color.emphasize'))
        .systemMaterial(LightAppearance.control($$.glowLevel))
        .accessibilityText($$.title)
        .id('background-running-' + $$.mode)
        .onChange((value: boolean) => { this.onToggleChange($$.mode, value); })
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  build() {
    Scroll(this.contentScroller) {
      Column({ space: 16 }) {
        Column() {
          this.ModeRow({
            mode: 'location',
            title: $r('app.string.background_running_location'),
            detail: $r('app.string.background_running_location_detail'),
            icon: $r('sys.symbol.connection'),
            isOn: this.locationEnabled,
            busy: this.busy,
            glowLevel: this.glowLevel
          })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.ModeRow({
            mode: 'pip',
            title: $r('app.string.background_running_pip'),
            detail: $r('app.string.background_running_pip_detail'),
            icon: $r('sys.symbol.play_circle'),
            isOn: this.pipEnabled,
            busy: this.busy,
            glowLevel: this.glowLevel
          })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.ModeRow({
            mode: 'audio',
            title: $r('app.string.background_running_audio'),
            detail: $r('app.string.background_running_audio_detail'),
            icon: $r('sys.symbol.speaker_wave_2'),
            isOn: this.audioEnabled,
            busy: this.busy,
            glowLevel: this.glowLevel
          })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.ModeRow({
            mode: 'download',
            title: $r('app.string.background_running_download'),
            detail: $r('app.string.background_running_download_detail'),
            icon: $r('sys.symbol.arrow_down_circle'),
            isOn: this.downloadEnabled,
            busy: this.busy,
            glowLevel: this.glowLevel
          })
        }
        .width('100%')
        .backgroundColor(this.groupBackground)
        .borderRadius(UiTokens.CARD_RADIUS)

        if (this.errorCode !== 0) {
          Column() {
            Text($r('app.string.background_running_error', this.errorCode.toString()))
              .fontSize(UiTokens.CAPTION_SIZE)
              .fontColor($r('sys.color.warning'))
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.groupBackground)
          .borderRadius(UiTokens.INSET_RADIUS)
          .id('background-running-error-banner')
        }

        Text($r('app.string.background_running_tips'))
          .fontSize(UiTokens.CAPTION_SIZE)
          .lineHeight(22)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin, right: this.contentMargin, top: 8, bottom: this.bottomInset })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.canvasBackground)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
    .id('background-running-settings')
  }
}
