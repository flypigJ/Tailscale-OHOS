import { common } from '@kit.AbilityKit';
import { MediaProbeState } from '../services/MediaIntegrationModels';
import { MotionTokens } from './MotionTokens';

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
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.displayedServiceNames.length > 0 ? $r('app.color.status_media_available') :
          $r('app.color.status_probe_pending'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .backgroundColor(this.displayedServiceNames.length > 0 ? $r('app.color.badge_background_media') :
          $r('app.color.badge_background_pending'))
        .borderRadius(8)
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: -4 })),
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
              .combine(TransitionEffect.translate({ y: -3 }))
          )
        )
    }
  }
}
