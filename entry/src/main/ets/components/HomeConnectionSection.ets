import { ConnectedHomeLayoutMode } from './HomeLayoutConfig';
import { MotionTokens } from './MotionTokens';

/** Selects one connected layout while leaving inactive/connecting/error UI unchanged. */
@Component
export struct HomeConnectionSection {
  @Prop connected: boolean = false;
  @Prop layoutMode: ConnectedHomeLayoutMode = ConnectedHomeLayoutMode.COMPACT;
  @BuilderParam inactiveHeader: () => void;
  @BuilderParam legacyHeader: () => void;
  @BuilderParam compactHeader: () => void;

  build() {
    if (!this.connected) {
      Column() {
        this.inactiveHeader()
      }
      .width('100%')
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 12 })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: -8 }))
        )
      )
    } else if (this.layoutMode === ConnectedHomeLayoutMode.LEGACY) {
      Column() {
        this.legacyHeader()
      }
      .width('100%')
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 12 })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: -8 }))
        )
      )
    } else {
      Column() {
        this.compactHeader()
      }
      .width('100%')
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 12 })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: -8 }))
        )
      )
    }
  }
}
