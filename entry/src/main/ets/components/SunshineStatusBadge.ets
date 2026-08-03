import { SunshineState } from '../services/StreamingModels';
import { MotionTokens } from './MotionTokens';

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
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.displayedState === 'available' ? $r('app.color.status_streaming_available') :
          $r('app.color.status_probe_pending'))
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .backgroundColor(this.displayedState === 'available' ? $r('app.color.badge_background_available') :
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
