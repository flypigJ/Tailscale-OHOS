import { UiTokens } from './UiTokens';
import { LightAppearance } from './LightAppearance';
@Component
export struct ConnectionDetailsSheet {
  @Prop tailscaleAddress: string = '';
  @Prop duration: string = '';
  @Prop downloadRate: string = '';
  @Prop uploadRate: string = '';
  @Prop downloadTotal: string = '';
  @Prop uploadTotal: string = '';
  @Prop exitNodeName: string = '';
  @Prop exitNodeAvailableCount: number = 0;
  @Prop allowLanAccess: boolean = false;
  onCopyAddress: () => void = () => {};

  private exitNodeLabel(): ResourceStr {
    if (this.exitNodeName.length > 0) {
      return this.exitNodeName;
    }
    if (this.exitNodeAvailableCount > 0) {
      return $r('app.string.network_sheet_not_used_available', this.exitNodeAvailableCount);
    }
    return $r('app.string.network_sheet_not_used');
  }

  @Builder
  private SectionTitle(title: ResourceStr): void {
    Text(title)
      .fontSize(UiTokens.SECTION_TITLE_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ left: 4, top: 8, bottom: 2 })
  }

  @Builder
  private DetailRow(label: ResourceStr, value: ResourceStr, actionable: boolean = false,
    action: () => void = () => {}): void {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(UiTokens.BODY_SIZE)
        .fontColor($r('sys.color.font_secondary'))
      Text(value)
        .fontSize(UiTokens.BODY_SIZE)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      if (actionable) {
        SymbolGlyph($r('sys.symbol.square_on_square_fill'))
          .fontSize(UiTokens.ICON_CHEVRON)
          .fontColor([$r('sys.color.icon_secondary')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 48 })
    .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 8, bottom: 8 })
    .onClick(() => {
      if (actionable) {
        action();
      }
    })
  }

  build() {
    Scroll() {
      Column({ space: UiTokens.GROUP_GAP }) {
        this.SectionTitle($r('app.string.network_sheet_network_title'))
        Column({ space: 0 }) {
          if (this.tailscaleAddress.length > 0) {
            this.DetailRow($r('app.string.network_sheet_local_address'), this.tailscaleAddress,
              true, this.onCopyAddress)
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          }
          this.DetailRow($r('app.string.exit_node_title'), this.exitNodeLabel())
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.DetailRow($r('app.string.network_sheet_lan_access'), this.allowLanAccess ?
            $r('app.string.network_sheet_on') : $r('app.string.network_sheet_off'))
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)

        this.SectionTitle($r('app.string.network_sheet_traffic_title'))
        Column({ space: 0 }) {
          this.DetailRow($r('app.string.network_sheet_duration'), this.duration)
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.DetailRow($r('app.string.network_sheet_current_rate'),
            `\u2193 ${this.downloadRate}   \u2191 ${this.uploadRate}`)
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
          this.DetailRow($r('app.string.network_sheet_session_traffic'),
            `\u2193 ${this.downloadTotal}   \u2191 ${this.uploadTotal}`)
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)

        Blank()
          .width('100%')
          .height(28)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .align(Alignment.TopStart)
    .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
  }
}
