import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BlurStrategy, hdsEffect, hdsMaterial } from '@kit.UIDesignKit';

/** App feedback policy; native material quality remains owned by the device and system settings. */
export class LightAppearance {
  private static initialized: boolean = false;
  private static immersiveSupported: boolean = false;
  private static deviceLevel: number = 2;
  private static materialState: uiMaterial.MaterialState = uiMaterial.MaterialState.DISABLE;
  private static hdsImmersiveSupported: boolean = false;
  private static readonly materials: Map<string, uiMaterial.Material> = new Map<string, uiMaterial.Material>();
  private static readonly effects: Map<string, VisualEffect> = new Map<string, VisualEffect>();
  private static emptyMaterial?: uiMaterial.Material;

  static supports(): boolean {
    LightAppearance.initialize();
    return LightAppearance.immersiveSupported &&
      LightAppearance.materialState !== uiMaterial.MaterialState.DISABLE;
  }

  /** Switch and Slider use their built-in material preset; Select consumes the available style options. */
  static control(level: number): uiMaterial.Material {
    return LightAppearance.material('control', level);
  }

  static menu(level: number): uiMaterial.Material {
    return LightAppearance.material('menu', level);
  }

  static sheet(level: number): uiMaterial.Material {
    return LightAppearance.material('sheet', level);
  }

  static dialog(level: number): uiMaterial.Material {
    return LightAppearance.material('dialog', level);
  }

  static toast(level: number): uiMaterial.Material {
    return LightAppearance.material('toast', level);
  }

  /** Only attach ordinary controls to supported native title-bar or bottom TabBar regions. */
  static toolbarButton(level: number): uiMaterial.Material {
    return LightAppearance.material('toolbar-button', level);
  }

  static toolbarGroup(level: number): uiMaterial.Material {
    return LightAppearance.material('toolbar-group', level);
  }

  static hdsLevel(level: number): hdsMaterial.MaterialLevel {
    LightAppearance.initialize();
    const preference: number = LightAppearance.preference(level);
    if (preference === 3) return hdsMaterial.MaterialLevel.ADAPTIVE;
    if (!LightAppearance.hdsImmersiveSupported) return hdsMaterial.MaterialLevel.SMOOTH;
    return preference === 0 ? hdsMaterial.MaterialLevel.EXQUISITE : preference === 1 ?
      hdsMaterial.MaterialLevel.GENTLE : hdsMaterial.MaterialLevel.SMOOTH;
  }

  static hdsType(level: number): hdsMaterial.MaterialType {
    LightAppearance.initialize();
    if (LightAppearance.materialState === uiMaterial.MaterialState.DISABLE) {
      return hdsMaterial.MaterialType.NONE;
    }
    return LightAppearance.preference(level) === 3 || !LightAppearance.hdsImmersiveSupported ?
      hdsMaterial.MaterialType.ADAPTIVE : hdsMaterial.MaterialType.IMMERSIVE;
  }

  static blurStrategy(level: number): BlurStrategy {
    LightAppearance.initialize();
    if (LightAppearance.materialState === uiMaterial.MaterialState.DISABLE) return BlurStrategy.DISABLE;
    if (LightAppearance.preference(level) === 3) return BlurStrategy.ADAPTIVE;
    const resolved: number = LightAppearance.resolvedLevel(level);
    return resolved === 0 ? BlurStrategy.ENABLE : resolved === 2 ? BlurStrategy.DISABLE : BlurStrategy.ADAPTIVE;
  }

  static backgroundRadius(level: number): number {
    const resolved: number = LightAppearance.resolvedLevel(level);
    return resolved === 0 ? 28 : resolved === 1 ? 18 : 10;
  }

  static backgroundSaturation(level: number): number {
    const resolved: number = LightAppearance.resolvedLevel(level);
    return resolved === 0 ? 1.38 : resolved === 1 ? 1.2 : 1.05;
  }

  static backgroundBrightness(level: number): number {
    const resolved: number = LightAppearance.resolvedLevel(level);
    return resolved === 0 ? 1.12 : resolved === 1 ? 1.07 : 1.02;
  }

  static pressEffect(level: number, pressed: boolean): VisualEffect {
    const resolved: number = LightAppearance.resolvedLevel(level);
    const key: string = `${resolved}:${pressed}`;
    const cached: VisualEffect | undefined = LightAppearance.effects.get(key);
    if (cached !== undefined) return cached;
    const shadow: hdsEffect.PressShadowType = !LightAppearance.supports() || !pressed || resolved === 2 ?
      hdsEffect.PressShadowType.NONE :
      resolved === 0 ? hdsEffect.PressShadowType.BLEND_GRADIENT : hdsEffect.PressShadowType.BLEND_WHITE;
    const effect: VisualEffect = new hdsEffect.HdsEffectBuilder().pressShadow(shadow).buildEffect();
    LightAppearance.effects.set(key, effect);
    return effect;
  }

  static nativePress(level: number): boolean {
    return !LightAppearance.supports() || LightAppearance.resolvedLevel(level) === 2;
  }

  private static material(role: string, level: number): uiMaterial.Material {
    const resolved: number = LightAppearance.resolvedLevel(level);
    const supported: boolean = LightAppearance.supports();
    const key: string = `${role}:${LightAppearance.preference(level)}:${resolved}:${supported}:${LightAppearance.materialState}`;
    const cached: uiMaterial.Material | undefined = LightAppearance.materials.get(key);
    if (cached !== undefined) return cached;
    if (!supported) {
      if (LightAppearance.emptyMaterial === undefined) LightAppearance.emptyMaterial = uiMaterial.Material.empty;
      LightAppearance.materials.set(key, LightAppearance.emptyMaterial);
      return LightAppearance.emptyMaterial;
    }
    const interactiveRole: boolean = role === 'control' || role === 'toolbar-button';
    const thinRole: boolean = role === 'control' || role === 'toolbar-button' || role === 'toolbar-group';
    const ultraThick: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.ULTRA_THICK ?? uiMaterial.ImmersiveStyle.THICK;
    const style: uiMaterial.ImmersiveStyle = (role === 'sheet' || role === 'dialog') ? ultraThick :
      thinRole ? uiMaterial.ImmersiveStyle.THIN : uiMaterial.ImmersiveStyle.THICK;
    const material: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
      style: style,
      colorInvert: thinRole,
      applyShadow: resolved !== 2,
      interactive: interactiveRole && resolved === 0,
      lightEffect: interactiveRole && resolved !== 2 ? { color: Color.White } : null
    });
    LightAppearance.materials.set(key, material);
    return material;
  }

  private static preference(level: number): number {
    return level === 0 || level === 1 || level === 2 ? level : 3;
  }

  private static resolvedLevel(level: number): number {
    LightAppearance.initialize();
    if (LightAppearance.materialState === uiMaterial.MaterialState.DISABLE) return 2;
    const preference: number = LightAppearance.preference(level);
    return preference === 3 ? LightAppearance.deviceLevel : preference;
  }

  private static initialize(): void {
    if (LightAppearance.initialized) return;
    LightAppearance.initialized = true;
    try {
      LightAppearance.immersiveSupported = uiMaterial.isImmersiveMaterialSupported() === true;
    } catch (_error) {}
    try {
      const level: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
      LightAppearance.deviceLevel = level === uiMaterial.MaterialLevel.EXQUISITE ? 0 :
        level === uiMaterial.MaterialLevel.GENTLE ? 1 : 2;
    } catch (_error) {}
    try {
      const state: uiMaterial.MaterialState = uiMaterial.getMaterialInfo().state;
      if (state === uiMaterial.MaterialState.DEFAULT || state === uiMaterial.MaterialState.ENABLE ||
        state === uiMaterial.MaterialState.DISABLE) LightAppearance.materialState = state;
    } catch (_error) {}
    try {
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      LightAppearance.hdsImmersiveSupported = Array.isArray(types) &&
        types.includes(hdsMaterial.MaterialType.IMMERSIVE);
    } catch (_error) {}
    hilog.info(0x0000, 'UiMaterialPolicy',
      'immersiveSupported=%{public}s deviceLevel=%{public}d hdsImmersiveSupported=%{public}s materialState=%{public}d',
      String(LightAppearance.immersiveSupported), LightAppearance.deviceLevel,
      String(LightAppearance.hdsImmersiveSupported), LightAppearance.materialState);
  }
}
