import { curves } from '@kit.ArkUI';
import { AnimationPreferences, AnimationSettings } from '../services/AnimationPreferences';

/** Shared motion parameters for app transitions and transient component changes. */
export class MotionTokens {
  static get FAST(): number {
    return MotionTokens.duration(160);
  }

  static get NORMAL(): number {
    return MotionTokens.duration(220);
  }

  static get EXPAND(): number {
    return MotionTokens.duration(260);
  }

  static get PAGE(): number {
    return MotionTokens.duration(320);
  }

  static duration(baseDuration: number): number {
    return MotionTokens.durationFor(baseDuration, AnimationPreferences.current().duration);
  }

  static durationFor(baseDuration: number, durationControl: number): number {
    const normalized: number = Math.min(100, Math.max(0, durationControl));
    const factor: number = 0.55 + normalized * 0.0075;
    return Math.max(1, Math.round(baseDuration * factor));
  }

  static amplitude(baseDistance: number): number {
    return baseDistance * MotionTokens.amplitudeScale(AnimationPreferences.current().amplitude);
  }

  static amplitudeScale(amplitudeControl: number): number {
    const normalized: number = Math.min(100, Math.max(0, amplitudeControl));
    return 0.55 + normalized * 0.008;
  }

  static curve(): ICurve {
    return MotionTokens.curveFor(AnimationPreferences.current());
  }

  static curveFor(settings: AnimationSettings): ICurve {
    const damping: number = Math.min(100, Math.max(0, settings.damping)) / 100;
    const amplitude: number = Math.min(100, Math.max(0, settings.amplitude)) / 100;
    if (settings.preset === 0) {
      return curves.cubicBezierCurve(0.18, 0, 0.24 + damping * 0.12, 1);
    }
    if (settings.preset === 2 || settings.preset === -1) {
      return curves.springCurve(amplitude * 0.18, 1, 210 + amplitude * 90, 14 + damping * 18);
    }
    return curves.cubicBezierCurve(0.24 + damping * 0.08, 0, 0.18 + amplitude * 0.1, 1);
  }
}
