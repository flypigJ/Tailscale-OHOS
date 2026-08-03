import { PeerPathResult, SunshineProbeResult } from '../services/StreamingModels';
import { MediaProbeResult } from '../services/MediaIntegrationModels';

@Component
export struct DeviceConnectionInfoPanel {
  @Prop path: PeerPathResult = { type: 'unknown', checkedAt: 0 };
  @Prop sunshine: SunshineProbeResult = { state: 'unknown', checkedAt: 0 };
  @Prop media: MediaProbeResult = { state: 'unknown', checkedAt: 0, services: [] };
  @Prop checking: boolean = false;
  @Prop refreshing: boolean = false;
  onRefresh: () => void = () => {};

  private pathLabel(): ResourceStr {
    if (this.checking) return $r('app.string.device_probe_checking');
    if (this.path.type === 'direct') return $r('app.string.device_path_direct', this.path.latencyMs ?? 0);
    if (this.path.type === 'peerRelay') {
      return $r('app.string.device_path_peer_relay', this.path.latencyMs ?? 0);
    }
    if (this.path.type === 'derp') return $r('app.string.device_path_derp_relay', this.path.latencyMs ?? 0);
    if (this.path.type === 'unreachable') return $r('app.string.device_path_unreachable');
    return $r('app.string.device_status_unknown');
  }

  private pathColor(): ResourceColor {
    if (this.checking) return $r('app.color.status_probe_pending');
    if (this.path.type === 'direct') return $r('app.color.status_path_direct');
    if (this.path.type === 'peerRelay' || this.path.type === 'derp') return $r('app.color.status_path_relay');
    return $r('app.color.status_path_unknown');
  }

  private sunshineLabel(): ResourceStr {
    if (this.sunshine.state === 'checking') return $r('app.string.device_probe_checking');
    if (this.sunshine.state === 'available') return $r('app.string.sunshine_available');
    if (this.sunshine.state === 'timeout') return $r('app.string.sunshine_timeout');
    if (this.sunshine.state === 'unavailable') return $r('app.string.sunshine_unavailable');
    if (this.sunshine.state === 'error') return $r('app.string.sunshine_failed');
    return $r('app.string.device_status_unknown');
  }

  private mediaLabel(): ResourceStr {
    if (this.media.state === 'checking') return $r('app.string.device_probe_checking');
    if (this.media.services.length > 0) {
      return this.media.services.map((service) => {
        if (service.type === 'jellyfin') return 'Jellyfin';
        if (service.type === 'emby') return 'Emby';
        if (service.type === 'plex') return 'Plex';
        if (service.type === 'webdav') return 'WebDAV';
        return 'SMB';
      }).join(' · ');
    }
    if (this.media.state === 'unavailable') return $r('app.string.media_services_unavailable');
    if (this.media.state === 'timeout') return $r('app.string.media_services_timeout');
    if (this.media.state === 'error') return $r('app.string.media_services_failed');
    return $r('app.string.device_status_unknown');
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text($r('app.string.device_connection_status')).fontSize(12).fontColor($r('sys.color.font_secondary'))
        Blank()
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(15)
          .fontColor([$r('sys.color.icon_secondary')])
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .enabled(!this.refreshing)
          .opacity(this.refreshing ? 0.55 : 1)
          .onClick(() => {
            if (!this.refreshing) {
              this.onRefresh();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 8, top: 10, bottom: 9 })
      Divider().color($r('app.color.divider_subtle'))
      Row() {
        Text($r('app.string.device_connection_path')).fontSize(12).fontColor($r('sys.color.font_secondary'))
        Row({ space: 6 }) {
          if (this.checking) {
            LoadingProgress().width(12).height(12).color($r('app.color.status_probe_spinner'))
          } else {
            Row().width(7).height(7).borderRadius(4).backgroundColor(this.pathColor())
          }
          Text(this.pathLabel()).fontSize(12).fontColor($r('sys.color.font_primary'))
        }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 10 })
      Divider().color($r('app.color.divider_subtle'))
      Row() {
        Text($r('app.string.streaming_label')).fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.sunshineLabel())
          .fontSize(12)
          .fontColor(this.sunshine.state === 'available' ? $r('app.color.status_streaming_available') :
            $r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 10 })
      Divider().color($r('app.color.divider_subtle'))
      Row() {
        Text($r('app.string.media_services_label')).fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.mediaLabel())
          .fontSize(12)
          .fontColor(this.media.services.length > 0 ? $r('app.color.status_media_available') :
            $r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 10 })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface_subtle'))
    .borderRadius(12)
  }
}
