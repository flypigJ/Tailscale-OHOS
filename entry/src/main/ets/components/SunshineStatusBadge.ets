import { SunshineState } from '../services/StreamingModels';
import { MotionTokens } from './MotionTokens';
import { UiTokens } from './UiTokens';

@Component
export struct SunshineStatusBadge {
  @Prop @Watch('onStateChanged') state: SunshineState = 'unknown';
  @State badgeVisible: boolean = false;
  @State displayedState: SunshineState = 'unknown';

  aboutToAppear(): void {
    if (this.shouldShow(this.state)) {
      this.displayedState = this.state;
      this.badgeVisible = true;
    }
  }

  private shouldShow(state: SunshineState): boolean {
    return state === 'available' || state === 'checking';
  }

  private onStateChanged(): void {
    if (this.shouldShow(this.state)) {
      this.displayedState = this.state;
      this.badgeVisible = true;
      return;
    }
    if (this.badgeVisible) {
      this.badgeVisible = false;
    }
  }

  build() {
    if (this.badgeVisible) {
      Text(this.displayedState === 'checking' ? $r('app.string.sunshine_checking') :
        $r('app.string.sunshine_available'))
        .fontSize(UiTokens.BADGE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.displayedState === 'available' ? $r('app.color.status_streaming_available') :
          $r('app.color.status_probe_pending'))
        .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
          top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
        .backgroundColor(this.displayedState === 'available' ? $r('app.color.badge_background_available') :
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
