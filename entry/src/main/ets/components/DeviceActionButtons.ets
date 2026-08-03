import { SunshineState } from '../services/StreamingModels';
import { MediaProbeState } from '../services/MediaIntegrationModels';

@Component
export struct DeviceActionButtons {
  @Prop sunshineState: SunshineState = 'unknown';
  @Prop reachable: boolean = true;
  @Prop meshConnected: boolean = false;
  @Prop peerOnline: boolean = false;
  @Prop ipAvailable: boolean = false;
  @Prop launching: boolean = false;
  @Prop showStreaming: boolean = true;
  @Prop mediaState: MediaProbeState = 'unknown';
  @Prop mediaCount: number = 0;
  @Prop mediaChecking: boolean = false;
  @Prop mediaLaunching: boolean = false;
  onStream: () => void = () => {};
  onDetectMedia: () => void = () => {};
  onMedia: () => void = () => {};
  onCopyIp: () => void = () => {};

  private canStream(): boolean {
    // The launch handler performs a fresh Sunshine/path probe. An unknown or
    // previously unreachable result must remain retryable while Mesh is live.
    return this.peerOnline && this.ipAvailable && this.meshConnected &&
      this.sunshineState !== 'checking' && !this.launching;
  }

  private canUseMedia(): boolean {
    return this.peerOnline && this.ipAvailable && this.meshConnected &&
      !this.mediaChecking && !this.mediaLaunching;
  }

  private canCopyIp(): boolean {
    return this.ipAvailable;
  }

  build() {
    Row({ space: 0 }) {
      Row() {
        Row({ space: 5 }) {
          if (this.launching || this.sunshineState === 'checking') {
            LoadingProgress().width(14).height(14).color($r('app.color.action_streaming_icon'))
          } else {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(15)
              .fontColor([$r('app.color.action_streaming_icon')])
          }
          Text($r('app.string.streaming_label'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.action_streaming_text'))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 6, right: 6 })
      .backgroundColor($r('app.color.action_streaming_surface'))
      .enabled(this.showStreaming && this.canStream())
      .opacity(this.showStreaming && this.canStream() ? 1 : 0.62)
      .accessibilityGroup(true)
      .accessibilityText($r('app.string.streaming_label'))
      .onClick(() => {
        if (this.showStreaming && this.canStream()) {
          this.onStream();
        }
      })

      Divider()
        .vertical(true)
        .height(24)
        .color($r('app.color.action_streaming_border'))

      Row() {
        Row({ space: 5 }) {
          if (this.mediaChecking || this.mediaLaunching) {
            LoadingProgress().width(14).height(14).color($r('app.color.action_media_progress'))
          } else {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(15)
              .fontColor([$r('app.color.action_media_icon')])
          }
          Text($r('app.string.media_services_label'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.action_media_text'))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 6, right: 6 })
      .backgroundColor($r('app.color.action_media_surface'))
      .enabled(this.canUseMedia())
      .opacity(this.canUseMedia() ? 1 : 0.62)
      .accessibilityGroup(true)
      .accessibilityText($r('app.string.media_services_label'))
      .onClick(() => {
        if (this.canUseMedia()) {
          if (this.mediaCount > 0) {
            this.onMedia();
          } else {
            this.onDetectMedia();
          }
        }
      })

      Divider()
        .vertical(true)
        .height(24)
        .color($r('app.color.action_media_border'))

      Row() {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(14)
            .fontColor([$r('sys.color.icon_primary')])
          Text($r('app.string.peer_copy_ip'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 6, right: 6 })
      .backgroundColor($r('app.color.action_copy_surface'))
      .enabled(this.canCopyIp())
      .opacity(this.canCopyIp() ? 1 : 0.62)
      .accessibilityGroup(true)
      .accessibilityText($r('app.string.peer_copy_ip'))
      .onClick(() => {
        if (this.canCopyIp()) {
          this.onCopyIp();
        }
      })
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.action_copy_surface'))
    .border({ width: 1, color: $r('app.color.action_copy_border') })
    .borderRadius(22)
    .clip(true)
  }
}
