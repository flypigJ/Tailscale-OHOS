import { UiTokens } from './UiTokens';
import { LightAppearance } from './LightAppearance';
import { MotionTokens } from './MotionTokens';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { APP_BACKGROUND_EVENT, APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { AnimationSettings, DEFAULT_ANIMATION_SETTINGS } from '../services/AnimationPreferences';
import { PersonalizationPreferences } from '../services/PersonalizationPreferences';
import {
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  DividerShowType,
  IconStyleMode
} from '@kit.UIDesignKit';

interface NativeSettingsSliderData {
  title: Resource;
  value: number;
  rowId: string;
  enabled: boolean;
  glowLevel: number;
  onChange: (value: number, mode: SliderChangeMode) => void;
}

interface NativeSettingsToggleData {
  title: ResourceStr;
  description: ResourceStr;
  isOn: boolean;
  glowLevel: number;
  onChange: (value: boolean) => void;
}

interface NativeSettingsPresetData {
  index: number;
  title: ResourceStr;
  selected: boolean;
}

interface NativeSettingsPreviewData {
  active: boolean;
  amplitude: number;
}

/**
 * Native settings surface used by the settings half-modal.
 *
 * Navigation owns the two detail pages while bindSheet owns presentation.
 * Keeping those responsibilities separate makes the sheet dismissible without
 * coupling the settings pages to the app's primary HdsNavigation stack.
 */
@Component
export struct NativeSettingsNavigation {
  @Prop glowLevel: number = 3;
  @Prop backgroundImageUri: string = '';
  @Prop backgroundUnavailable: boolean = false;
  @Prop backgroundBrightnessValue: number = 52;
  @Prop immersiveColorTint: ResourceColor = $r('app.color.emphasize');
  @Prop backgroundPickerInProgress: boolean = false;
  @Prop backgroundClearEnabled: boolean = false;
  @Prop immersiveColorEnabled: boolean = false;
  @Prop @Watch('onPageNameChanged') pageName: string = 'background';
  onGlowLevelChange: (level: number) => void = (_level: number) => {};
  onSelectBackground: () => void = () => {};
  onClearBackground: () => void = () => {};
  onBackgroundImageError: (uri: string) => void = (_uri: string) => {};
  onBackgroundBrightnessChange: (value: number, mode: SliderChangeMode) => void =
    (_value: number, _mode: SliderChangeMode) => {};
  onImmersiveColorChange: (enabled: boolean) => void = (_enabled: boolean) => {};
  onAnimationSettingsChange: (settings: AnimationSettings) => void = (_settings: AnimationSettings) => {};
  onDismiss: () => void = () => {};

  @Prop initialAnimationDuration: number = DEFAULT_ANIMATION_SETTINGS.duration;
  @Prop initialAnimationAmplitude: number = DEFAULT_ANIMATION_SETTINGS.amplitude;
  @Prop initialAnimationDamping: number = DEFAULT_ANIMATION_SETTINGS.damping;
  @Prop initialAnimationPreset: number = DEFAULT_ANIMATION_SETTINGS.preset;
  @State animationDuration: number = DEFAULT_ANIMATION_SETTINGS.duration;
  @State animationAmplitude: number = DEFAULT_ANIMATION_SETTINGS.amplitude;
  @State animationDamping: number = DEFAULT_ANIMATION_SETTINGS.damping;
  @State animationPreset: number = DEFAULT_ANIMATION_SETTINGS.preset;
  @State previewActive: boolean = false;
  @State materialIndex: number = 3;

  private backgroundScroller: Scroller = new Scroller();
  private animationScroller: Scroller = new Scroller();
  private previewLoopTimer: number = -1;
  private previewLoopGeneration: number = 0;
  private previewLoopRunning: boolean = false;
  private previewComponentVisible: boolean = false;
  private previewInViewport: boolean = false;
  private previewAppForeground: boolean = true;
  private appForegroundListener: () => void = () => {
    this.previewAppForeground = true;
    this.startPreviewLoop();
  };
  private appBackgroundListener: () => void = () => {
    this.previewAppForeground = false;
    this.stopPreviewLoop();
  };

  aboutToAppear(): void {
    this.materialIndex = this.glowLevel >= 0 && this.glowLevel <= 3 ? this.glowLevel : 3;
    this.animationDuration = this.initialAnimationDuration;
    this.animationAmplitude = this.initialAnimationAmplitude;
    this.animationDamping = this.initialAnimationDamping;
    this.animationPreset = this.initialAnimationPreset;
    this.previewComponentVisible = true;
    this.previewAppForeground = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.on(APP_FOREGROUND_EVENT, this.appForegroundListener);
    context.eventHub.on(APP_BACKGROUND_EVENT, this.appBackgroundListener);
    this.startPreviewLoop();
  }

  aboutToDisappear(): void {
    this.previewComponentVisible = false;
    this.previewInViewport = false;
    this.stopPreviewLoop();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.off(APP_FOREGROUND_EVENT, this.appForegroundListener);
    context.eventHub.off(APP_BACKGROUND_EVENT, this.appBackgroundListener);
  }

  private onPageNameChanged(): void {
    this.stopPreviewLoop();
    this.startPreviewLoop();
  }

  private modalTitleBar(title: ResourceStr): HdsNavigationTitleBarOptions {
    return {
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: title },
        menu: {
          value: [{
            content: {
              label: $r('app.string.native_settings_close'),
              icon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
                .fontColor([$r('sys.color.icon_primary')]),
              isEnabled: true,
              type: IconStyleMode.SMALL,
              action: () => this.onDismiss()
            }
          }]
        },
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        blurStrategy: LightAppearance.blurStrategy(this.materialIndex),
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary'),
              textColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: LightAppearance.hdsType(this.materialIndex),
          materialLevel: LightAppearance.hdsLevel(this.materialIndex)
        }
      }
    };
  }

  private materialLabel(): ResourceStr {
    switch (this.materialIndex) {
      case 0: return $r('app.string.native_settings_material_exquisite');
      case 1: return $r('app.string.native_settings_material_gentle');
      case 2: return $r('app.string.native_settings_material_smooth');
      default: return $r('app.string.native_settings_material_adaptive');
    }
  }

  private selectMaterial(index: number): void {
    if (index < 0 || index > 3) {
      return;
    }
    this.materialIndex = index;
    this.onGlowLevelChange(index);
  }

  private canRunPreviewLoop(): boolean {
    return this.previewComponentVisible && this.previewInViewport && this.previewAppForeground &&
      this.pageName === 'animation';
  }

  private isCurrentPreviewLoop(generation: number): boolean {
    return this.previewLoopRunning && generation === this.previewLoopGeneration && this.canRunPreviewLoop();
  }

  private startPreviewLoop(): void {
    if (!this.canRunPreviewLoop() || this.previewLoopRunning) return;
    this.previewLoopRunning = true;
    const generation: number = ++this.previewLoopGeneration;
    // Let the preview enter the component tree before starting its first transition.
    this.schedulePreviewCycle(generation, 16);
  }

  private stopPreviewLoop(): void {
    this.previewLoopRunning = false;
    this.previewLoopGeneration++;
    if (this.previewLoopTimer >= 0) {
      clearTimeout(this.previewLoopTimer);
      this.previewLoopTimer = -1;
    }
  }

  private restartPreviewLoop(): void {
    this.stopPreviewLoop();
    this.startPreviewLoop();
  }

  private onPreviewVisibilityChanged(visible: boolean): void {
    this.previewInViewport = visible;
    if (visible) this.startPreviewLoop();
    else this.stopPreviewLoop();
  }

  private schedulePreviewCycle(generation: number, delayMs: number): void {
    if (!this.isCurrentPreviewLoop(generation)) return;
    if (this.previewLoopTimer >= 0) clearTimeout(this.previewLoopTimer);
    this.previewLoopTimer = setTimeout(() => {
      if (!this.isCurrentPreviewLoop(generation)) return;
      this.previewLoopTimer = -1;
      this.runPreviewCycle(generation);
    }, delayMs);
  }

  private runPreviewCycle(generation: number): void {
    if (!this.isCurrentPreviewLoop(generation)) return;
    // Read the latest controls once per cycle; callbacks never retain a settings snapshot for later cycles.
    const settings: AnimationSettings = this.currentAnimationSettings();
    const duration: number = this.animationDurationMs(settings.duration);
    try {
      this.getUIContext().animateTo({
        duration: duration,
        curve: MotionTokens.curveFor(settings)
      }, () => {
        if (this.isCurrentPreviewLoop(generation)) this.previewActive = !this.previewActive;
      });
    } catch (_error) {
      this.stopPreviewLoop();
      return;
    }
    // One timeout owns the next leg of the ping-pong motion. Restart/leave invalidates both callbacks.
    this.schedulePreviewCycle(generation, duration + 80);
  }

  private animationDurationMs(duration: number = this.animationDuration): number {
    return MotionTokens.durationFor(400, duration);
  }

  private currentAnimationSettings(): AnimationSettings {
    return {
      preset: this.animationPreset,
      duration: this.animationDuration,
      amplitude: this.animationAmplitude,
      damping: this.animationDamping
    };
  }

  private applyAnimationSettingsLocally(settings: AnimationSettings): void {
    this.animationPreset = settings.preset;
    this.animationDuration = settings.duration;
    this.animationAmplitude = settings.amplitude;
    this.animationDamping = settings.damping;
  }

  private updateAnimationSettings(settings: AnimationSettings, mode: SliderChangeMode): void {
    this.applyAnimationSettingsLocally(settings);
    this.onAnimationSettingsChange(settings);
    if (mode === SliderChangeMode.End) this.restartPreviewLoop();
  }

  private updateAnimationControl(control: string, value: number, mode: SliderChangeMode): void {
    if (!Number.isFinite(value)) return;
    const settings: AnimationSettings = this.currentAnimationSettings();
    const normalized: number = Math.min(100, Math.max(0, Math.round(value)));
    settings.preset = -1;
    if (control === 'duration') settings.duration = normalized;
    else if (control === 'amplitude') settings.amplitude = normalized;
    else if (control === 'damping') settings.damping = normalized;
    else return;
    this.updateAnimationSettings(settings, mode);
  }

  private applyPreset(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index > 2) return;
    let duration: number = 60;
    let amplitude: number = 56;
    let damping: number = 64;
    if (index === 0) {
      duration = 28;
      amplitude = 32;
      damping = 82;
    } else if (index === 2) {
      duration = 78;
      amplitude = 72;
      damping = 42;
    }

    const settings: AnimationSettings = {
      preset: index,
      duration: duration,
      amplitude: amplitude,
      damping: damping
    };
    // Commit controls and persistence immediately. Only the preview's geometry is animated.
    this.applyAnimationSettingsLocally(settings);
    this.onAnimationSettingsChange(settings);
    this.restartPreviewLoop();
  }

  @Builder
  private PreviewCard($$: NativeSettingsPreviewData): void {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: 12 }) {
          Row({ space: 6 }) {
            Circle().width(7).height(7).fill($r('app.color.emphasize'))
            Circle().width(7).height(7).fill($r('sys.color.comp_divider'))
            Circle().width(7).height(7).fill($r('sys.color.comp_divider'))
          }
            .width('100%')
            .padding({ left: 16 })

          Stack({ alignContent: Alignment.Center }) {
            Column({ space: 10 }) {
              Row()
                .width(52)
                .height(8)
                .borderRadius(4)
                .backgroundColor($r('app.color.emphasize'))
              Row()
                .width(74)
                .height(7)
                .borderRadius(4)
                .backgroundColor($r('sys.color.comp_divider'))
              Row({ space: 7 }) {
                Circle().width(20).height(20).fill($r('app.color.preview_accent_teal'))
                Row()
                  .width(50)
                  .height(28)
                  .borderRadius(8)
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
              }
            }
              .width(122)
              .height(116)
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(16)
              .shadow({ radius: 16, color: $r('app.color.shadow_card_soft'), offsetY: 6 })
              .rotate({ angle: ($$.active ? 1 : -1) * (1.5 + $$.amplitude * 0.025) })
              .translate({ x: ($$.active ? 1 : -1) * 38 * MotionTokens.amplitudeScale($$.amplitude) })
              .id('native-settings-preview-primary')

            Column({ space: 10 }) {
              Row({ space: 6 }) {
                Circle().width(24).height(24).fill($r('app.color.preview_accent_amber'))
                Column({ space: 4 }) {
                  Row()
                    .width(48)
                    .height(7)
                    .borderRadius(4)
                    .backgroundColor($r('app.color.emphasize'))
                  Row()
                    .width(34)
                    .height(6)
                    .borderRadius(3)
                    .backgroundColor($r('sys.color.comp_divider'))
                }
              }
              Row()
                .width(82)
                .height(34)
                .borderRadius(9)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
              Row()
                .width(64)
                .height(7)
                .borderRadius(4)
                .backgroundColor($r('sys.color.comp_divider'))
            }
              .width(122)
              .height(116)
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(16)
              .shadow({ radius: 16, color: $r('app.color.shadow_card_soft'), offsetY: 6 })
              .rotate({ angle: ($$.active ? -1 : 1) * (1.5 + $$.amplitude * 0.025) })
              .translate({ x: ($$.active ? -1 : 1) * 38 * MotionTokens.amplitudeScale($$.amplitude) })
              .id('native-settings-preview-secondary')
          }
            .width('100%')
            .layoutWeight(1)

          Stack({ alignContent: Alignment.Center }) {
            Row()
              .width(64)
              .height(5)
              .borderRadius(3)
              .backgroundColor($r('sys.color.comp_divider'))
            Circle()
              .width(11)
              .height(11)
              .fill($r('app.color.emphasize'))
              .translate({ x: $$.active ? 22 : -22 })
              .id('native-settings-preview-indicator')
          }
            .width('100%')
            .height(14)
        }
          .width('86%')
          .height(198)
          .padding({ top: 14, bottom: 12 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius(20)
      }
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius(24)
        .clip(true)
    }
      .width('100%')
      .height(240)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 24 })
      .id('native-settings-preview')
      .accessibilityText($r('app.string.native_settings_preview_hint'))
      .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number) =>
        this.onPreviewVisibilityChanged(ratio > 0))
      .onClick(() => this.restartPreviewLoop())
  }

  private backgroundBrightnessEnabled(): boolean {
    return (this.backgroundImageUri.length > 0 && !this.backgroundUnavailable) || this.immersiveColorEnabled;
  }

  @Builder
  private BackgroundPreviewImage(uri: string): void {
    Image(uri)
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Cover)
      .opacity(this.immersiveColorEnabled ? 0.48 : 0.36)
      .brightness(PersonalizationPreferences.backgroundBrightnessFactor(this.backgroundBrightnessValue))
      .onError(() => this.onBackgroundImageError(uri))
  }

  @Builder
  private BackgroundPreviewCard(): void {
    Stack({ alignContent: Alignment.Center }) {
      if (this.backgroundImageUri.length > 0 && !this.backgroundUnavailable) {
        this.BackgroundPreviewImage(this.backgroundImageUri)
      }
      if (this.immersiveColorEnabled) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.immersiveColorTint)
          .brightness(PersonalizationPreferences.backgroundBrightnessFactor(this.backgroundBrightnessValue))
      }
      if (this.backgroundUnavailable) {
        Text($r('app.string.personalization_background_unavailable'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.Center)
          .padding(UiTokens.CARD_PADDING)
      }
    }
      .borderRadius(24)
      .clip(true)
      .width('100%')
      .height(220)
      .backgroundColor($r('sys.color.background_secondary'))
      .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 24 })
      .id('native-settings-background-preview')
  }

  @Builder
  private ToggleRow($$: NativeSettingsToggleData): void {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text($$.title)
          .fontSize(UiTokens.SECTION_TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($$.description)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: $$.isOn })
        .selectedColor($r('app.color.emphasize'))
        .onChange((value: boolean) => $$.onChange(value))
        .systemMaterial(LightAppearance.control($$.glowLevel))
    }
      .width('100%')
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 16, bottom: 16 })
  }

  @Builder
  private SliderRow($$: NativeSettingsSliderData): void {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text($$.title)
          .fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(`${Math.round($$.value)}%`)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .opacity($$.enabled ? 1 : 0.55)
      Slider({ value: $$.value, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .width('100%')
        .enabled($$.enabled)
        .accessibilityText($$.title)
        .accessibilityDescription(`${Math.round($$.value)}%`)
        .onChange((value: number, mode: SliderChangeMode) => $$.onChange(value, mode))
        .id($$.rowId)
        .systemMaterial(LightAppearance.control($$.glowLevel))
    }
      .width('100%')
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 16, bottom: 16 })
  }

  @Builder
  private BackgroundPage(): void {
    Column() {
      Scroll(this.backgroundScroller) {
        Column({ space: UiTokens.GROUP_GAP }) {
          this.BackgroundPreviewCard()
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 12 }) {
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.picture'))
                  .fontSize(UiTokens.ICON_LIST_LEADING)
                  .fontColor([$r('app.color.emphasize')])
              }
                .width(UiTokens.ICON_LIST_CONTAINER)
                .height(UiTokens.ICON_LIST_CONTAINER)
                .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
              Text($r('app.string.native_settings_choose_background'))
                .fontSize(UiTokens.SECTION_TITLE_SIZE)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(UiTokens.ICON_CHEVRON)
                .fontColor([$r('sys.color.icon_secondary')])
            }
              .width('100%')
              .height('100%')
              .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          }
            .width('100%')
            .height(64)
            .padding(0)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
            .enabled(!this.backgroundPickerInProgress)
            .id('native-settings-choose-background')
            .onClick(() => this.onSelectBackground())

          Column() {
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              Row({ space: 12 }) {
                Stack({ alignContent: Alignment.Center }) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(UiTokens.ICON_LIST_LEADING)
                    .fontColor([$r('app.color.status_error')])
                }
                  .width(UiTokens.ICON_LIST_CONTAINER)
                  .height(UiTokens.ICON_LIST_CONTAINER)
                  .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
                  .backgroundColor($r('app.color.badge_background_error'))
                Text($r('app.string.native_settings_clear_background'))
                  .fontSize(UiTokens.SECTION_TITLE_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.status_error'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.Start)
              }
                .width('100%')
                .height('100%')
                .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
            }
              .width('100%')
              .height(64)
              .padding(0)
              .backgroundColor(Color.Transparent)
              .enabled(this.backgroundClearEnabled)
              .id('native-settings-clear-background')
              .onClick(() => this.onClearBackground())
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
            .clip(true)

          Column({ space: 0 }) {
            this.ToggleRow({ title: $r('app.string.native_settings_immersive_color'),
              description: $r('app.string.native_settings_immersive_color_desc'),
              isOn: this.immersiveColorEnabled, glowLevel: this.materialIndex,
              onChange: (value: boolean) => this.onImmersiveColorChange(value) })
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
            .clip(true)

          Column({ space: 0 }) {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text($r('app.string.native_settings_material'))
                  .fontSize(UiTokens.SECTION_TITLE_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                Text($r('app.string.native_settings_material_desc'))
                  .fontSize(UiTokens.CAPTION_SIZE)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
              }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              Select([
                { value: $r('app.string.native_settings_material_exquisite') },
                { value: $r('app.string.native_settings_material_gentle') },
                { value: $r('app.string.native_settings_material_smooth') },
                { value: $r('app.string.native_settings_material_adaptive') }
              ])
                .id('native-settings-material-select')
                .selected(this.materialIndex)
                .value(this.materialLabel())
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .controlSize(ControlSize.SMALL)
                .constraintSize({ minWidth: 104, maxWidth: 128 })
                .onSelect((index: number) => this.selectMaterial(index))
                .systemMaterial(LightAppearance.control(this.materialIndex))
                .menuSystemMaterial(LightAppearance.menu(this.materialIndex))
            }
              .width('100%')
              .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 16, bottom: 16 })
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow({ title: $r('app.string.native_settings_brightness'),
              value: this.backgroundBrightnessValue, rowId: 'native-settings-background-brightness',
              glowLevel: this.materialIndex,
              enabled: (this.backgroundImageUri.length > 0 && !this.backgroundUnavailable) ||
                this.immersiveColorEnabled,
              onChange: (value: number, mode: SliderChangeMode) => this.onBackgroundBrightnessChange(value, mode) })
            Text(((this.backgroundImageUri.length > 0 && !this.backgroundUnavailable) ||
              this.immersiveColorEnabled) ? $r('app.string.native_settings_brightness_desc') :
              $r('app.string.native_settings_brightness_inactive_desc'))
              .fontSize(UiTokens.CAPTION_SIZE)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, bottom: 16 })
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
            .clip(true)

        }
          .width('100%')
          .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, bottom: 28 })
      }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
  }

  @Builder
  private AnimationPage(): void {
    Column() {
      Scroll(this.animationScroller) {
        Column({ space: UiTokens.GROUP_GAP }) {
          this.PreviewCard({ active: this.previewActive, amplitude: this.animationAmplitude })
          Text($r('app.string.native_settings_preview_hint'))
            .fontSize(UiTokens.CAPTION_SIZE)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Column({ space: 0 }) {
            this.SliderRow({ title: $r('app.string.native_settings_animation_duration'),
              value: this.animationDuration, rowId: 'native-settings-animation-duration', enabled: true, glowLevel: this.materialIndex,
              onChange: (value: number, mode: SliderChangeMode) =>
                this.updateAnimationControl('duration', value, mode) })
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow({ title: $r('app.string.native_settings_animation_amplitude'),
              value: this.animationAmplitude, rowId: 'native-settings-animation-amplitude', enabled: true, glowLevel: this.materialIndex,
              onChange: (value: number, mode: SliderChangeMode) =>
                this.updateAnimationControl('amplitude', value, mode) })
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow({ title: $r('app.string.native_settings_animation_damping'),
              value: this.animationDamping, rowId: 'native-settings-animation-damping', enabled: true, glowLevel: this.materialIndex,
              onChange: (value: number, mode: SliderChangeMode) =>
                this.updateAnimationControl('damping', value, mode) })
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
            .clip(true)

          Text($r('app.string.native_settings_animation_scale_desc'))
            .fontSize(UiTokens.CAPTION_SIZE)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 4, right: 4 })

          Row({ space: 10 }) {
            this.PresetButton({ index: 0, title: $r('app.string.native_settings_preset_efficiency'),
              selected: this.animationPreset === 0 })
            this.PresetButton({ index: 1, title: $r('app.string.native_settings_preset_default'),
              selected: this.animationPreset === 1 })
            this.PresetButton({ index: 2, title: $r('app.string.native_settings_preset_lively'),
              selected: this.animationPreset === 2 })
          }
            .width('100%')
            .height(54)
            .justifyContent(FlexAlign.SpaceBetween)
        }
          .width('100%')
          .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, bottom: 28 })
      }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
  }

  @Builder
  private PresetButton($$: NativeSettingsPresetData): void {
    Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
      Text($$.title)
        .fontSize(UiTokens.BODY_SIZE)
        .fontColor($$.selected ? $r('app.color.selection_foreground') :
          $r('sys.color.font_primary'))
    }
      .layoutWeight(1)
      .height(54)
      .padding(0)
      .backgroundColor($$.selected ? $r('app.color.selection_background') :
        $r('sys.color.comp_background_primary'))
      .id('native-settings-preset-' + $$.index)
      .onClick(() => this.applyPreset($$.index))
  }

  build() {
    HdsNavigation() {
      if (this.pageName === 'animation') {
        this.AnimationPage()
      } else {
        this.BackgroundPage()
      }
    }
      .titleMode(HdsNavigationTitleMode.MODAL)
      .titleBar(this.modalTitleBar(this.pageName === 'animation' ?
        $r('app.string.native_settings_animation') :
        $r('app.string.native_settings_background_material')))
      .bindToScrollable([this.pageName === 'animation' ?
        this.animationScroller : this.backgroundScroller])
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      .id(this.pageName === 'animation' ?
        'native-animation-settings' : 'native-background-material-settings')
  }
}
