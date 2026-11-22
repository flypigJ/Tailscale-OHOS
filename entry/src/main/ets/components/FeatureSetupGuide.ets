import { UiTokens } from './UiTokens';
import { FEATURE_GUIDE_SECTIONS, FeatureGuideSection } from '../services/FeatureGuideCatalog';
import { ResponsiveLayout } from './ResponsiveLayout';

@CustomDialog
export struct FeatureSetupDialog {
  controller?: CustomDialogController;
  initialSection: string = '';
  presentationId: number = 0;

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.feature_guide_title'))
        .fontSize(UiTokens.SECTION_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
      FeatureSetupGuide({ initialSection: this.initialSection, presentationId: this.presentationId })
        .layoutWeight(1)
      Button($r('app.string.taildrive_done_action'), { buttonStyle: ButtonStyleMode.TEXTUAL })
        .width('100%')
        .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
        .id('feature-guide-dialog-close')
        .onClick(() => this.controller?.close())
    }
    .width('100%')
    .height('100%')
    .padding({ top: 20, bottom: 12 })
    .id('feature-guide-dialog')
  }
}

/** Offline, read-only instructions. No account changes or shell execution. */
@Component
export struct FeatureSetupGuide {
  contentScroller: Scroller = new Scroller();
  @Prop @Watch('onInitialSectionChanged') initialSection: string = '';
  @Prop @Watch('onInitialSectionChanged') presentationId: number = 0;
  @Prop contentMargin: number = UiTokens.PAGE_PADDING;
  @Prop bottomInset: number = 32;
  @State expandedSection: string = '';
  @State advancedSection: string = '';

  aboutToAppear(): void {
    this.onInitialSectionChanged();
  }

  private onInitialSectionChanged(): void {
    this.expandedSection = this.initialSection === 'transfer' ? 'taildrop' : this.initialSection;
    this.advancedSection = '';
  }

  private visibleSections(): FeatureGuideSection[] {
    if (this.initialSection === 'transfer') {
      return FEATURE_GUIDE_SECTIONS.filter((section: FeatureGuideSection) =>
        section.id === 'taildrop' || section.id === 'localsend');
    }
    if (this.initialSection.length > 0) {
      return FEATURE_GUIDE_SECTIONS.filter((section: FeatureGuideSection) => section.id === this.initialSection);
    }
    return FEATURE_GUIDE_SECTIONS;
  }

  @Builder
  private CopyableExample(hint: Resource, content: string, exampleId: string) {
    Column({ space: 8 }) {
      Text(hint)
        .fontSize(UiTokens.CAPTION_SIZE)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(content)
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor($r('sys.color.font_primary'))
        .copyOption(CopyOptions.LocalDevice)
        .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
        .width('100%')
        .id(exampleId)
    }
      .width('100%')
      .padding(12)
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius(UiTokens.INSET_RADIUS)
  }

  @Builder
  private FeatureCard(section: FeatureGuideSection) {
    Column({ space: 0 }) {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 12 }) {
          Text(section.title)
            .fontSize(UiTokens.SECTION_TITLE_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
          SymbolGlyph(this.expandedSection === section.id ?
            $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
        }
          .width('100%')
          .padding(UiTokens.CARD_PADDING)
      }
        .width('100%')
        .padding(0)
        .backgroundColor(Color.Transparent)
        .id('feature-guide-toggle-' + section.id)
        .onClick(() => {
          this.expandedSection = this.expandedSection === section.id ? '' : section.id;
        })
      if (this.expandedSection === section.id) {
        Column({ space: UiTokens.GROUP_GAP }) {
          Text(section.body)
            .fontSize(UiTokens.BODY_SIZE)
            .lineHeight(24)
            .fontColor($r('sys.color.font_primary'))
            .copyOption(CopyOptions.LocalDevice)
            .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
            .width('100%')
          if (section.policy.length > 0 || section.commands.length > 0) {
            Button($r('app.string.feature_guide_advanced'), {
              buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
            })
              .fontSize(UiTokens.BODY_SIZE)
              .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
              .id('feature-guide-advanced-' + section.id)
              .onClick(() => {
                this.advancedSection = this.advancedSection === section.id ? '' : section.id;
              })
            if (this.advancedSection === section.id) {
              if (section.policy.length > 0) {
                this.CopyableExample($r('app.string.feature_guide_policy_hint'), section.policy,
                  'feature-guide-policy-' + section.id)
              }
              if (section.commands.length > 0) {
                this.CopyableExample($r('app.string.feature_guide_commands_hint'), section.commands,
                  'feature-guide-commands-' + section.id)
              }
            }
          }
          if (section.reference.length > 0) {
            this.CopyableExample($r('app.string.feature_guide_reference_hint'), section.reference,
              'feature-guide-reference-' + section.id)
          }
        }
          .width('100%')
          .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, bottom: 16 })
      }
    }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(UiTokens.CARD_RADIUS)
  }

  build() {
    Scroll(this.contentScroller) {
      Column({ space: UiTokens.GROUP_GAP }) {
        Text($r('app.string.feature_guide_intro'))
          .fontSize(UiTokens.BODY_SIZE)
          .lineHeight(24)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
        ForEach(this.visibleSections(), (section: FeatureGuideSection) => {
          this.FeatureCard(section)
        }, (section: FeatureGuideSection) => section.id)
      }
        .width('100%')
        .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
        .padding({ left: this.contentMargin, right: this.contentMargin, top: 12, bottom: this.bottomInset })
    }
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .id('feature-setup-guide')
  }
}
