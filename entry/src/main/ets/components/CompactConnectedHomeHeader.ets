@Component
export struct CompactConnectedHomeHeader {
  @Prop statusTitle: ResourceStr = '';
  @Prop statusDescription: ResourceStr = '';
  @Prop statusColor: ResourceColor = $r('app.color.status_offline');
  @Prop downloadRate: string = '0 B/s';
  @Prop uploadRate: string = '0 B/s';
  @Prop showTraffic: boolean = true;
  @Prop exitNodeLabel: ResourceStr = '';
  @Prop exitNodeEditable: boolean = false;
  @Prop exitNodeEnabled: boolean = false;
  @Prop exitNodeOptions: SelectOption[] = [];
  @Prop exitNodeSelectedIndex: number = 0;
  onDetails: () => void = () => {};
  onExitNodeInfo: () => void = () => {};
  onExitNodeSelect: (index: number) => void = (_index: number) => {};
  @BuilderParam connectionButton: () => void;
  @BuilderParam trafficBackdrop: () => void;

  build() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Column({ space: 1 }) {
          Row({ space: 6 }) {
            Text(this.statusTitle)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Row()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.statusColor)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text(this.statusDescription)
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .onClick(this.onDetails)
        this.connectionButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showTraffic) {
        Stack({ alignContent: Alignment.Center }) {
          this.trafficBackdrop()
          Row({ space: 12 }) {
            Text(`\u2193 ${this.downloadRate}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.icon_emphasize'))
              .layoutWeight(1)
            Text(`\u2191 ${this.uploadRate}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.traffic_upload'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 10, right: 10 })
        }
        .width('100%')
        .height(38)
        .clip(true)
        .borderRadius(10)
        .onClick(this.onDetails)
      }

      Row({ space: 8 }) {
        Text($r('app.string.exit_node_title'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        if (this.exitNodeEditable) {
          Blank()
          Select(this.exitNodeOptions)
            .id('exit-node-status')
            .selected(this.exitNodeSelectedIndex)
            .value(this.exitNodeLabel)
            .controlSize(ControlSize.SMALL)
            .font({ size: 12 })
            .optionFont({ size: 12 })
            .selectedOptionFont({ size: 12 })
            .menuBackgroundColor($r('sys.color.comp_background_tertiary'))
            .menuBackgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
            .constraintSize({ minWidth: 104, maxWidth: 160 })
            .enabled(this.exitNodeEnabled)
            .opacity(this.exitNodeEnabled ? 1 : 0.55)
            .onSelect((index: number) => this.onExitNodeSelect(index))
        } else {
          Text(this.exitNodeLabel)
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.End)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('sys.color.icon_secondary')])
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 28 })
      .onClick(() => {
        if (!this.exitNodeEditable) {
          this.onExitNodeInfo();
        }
      })
    }
    .id('compact-connected-home-header')
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }
}
