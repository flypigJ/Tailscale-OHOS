import { common } from '@kit.AbilityKit';
import { MediaProbeState } from '../services/MediaIntegrationModels';
import { MotionTokens } from './MotionTokens';
import { UiTokens } from './UiTokens';

@Component
export struct MediaStatusBadge {
  @Prop @Watch('onBadgeStateChanged') state: MediaProbeState = 'unknown';
  @Prop @Watch('onBadgeStateChanged') serviceNames: string = '';
  @State badgeVisible: boolean = false;
  @State displayedState: MediaProbeState = 'unknown';
  @State displayedServiceNames: string = '';

  aboutToAppear(): void {
    if (this.shouldShow()) {
      this.displayedState = this.state;
      this.displayedServiceNames = this.serviceNames;
      this.badgeVisible = true;
    }
  }

  private shouldShow(): boolean {
    return this.state === 'checking' || this.serviceNames.length > 0;
  }

  private onBadgeStateChanged(): void {
    if (this.shouldShow()) {
      this.displayedState = this.state;
      this.displayedServiceNames = this.serviceNames;
      this.badgeVisible = true;
      return;
    }
    if (this.badgeVisible) {
      this.badgeVisible = false;
    }
  }

  private mediaAvailableText(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.resourceManager.getStringSync($r('app.string.media_services_available').id,
      this.displayedServiceNames);
  }

  build() {
    if (this.badgeVisible) {
      Text(this.displayedState === 'checking' ? $r('app.string.media_services_checking') :
        this.mediaAvailableText())
        .fontSize(UiTokens.BADGE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.displayedServiceNames.length > 0 ? $r('app.color.status_media_available') :
          $r('app.color.status_probe_pending'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
          top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
        .backgroundColor(this.displayedServiceNames.length > 0 ? $r('app.color.badge_background_media') :
          $r('app.color.badge_background_pending'))
        .borderRadius(UiTokens.BADGE_RADIUS)
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-4) })),
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-3) }))
          )
        )
    }
  }
}
