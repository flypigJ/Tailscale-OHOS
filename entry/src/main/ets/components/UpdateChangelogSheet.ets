import { UiTokens } from './UiTokens';
import { LightAppearance } from './LightAppearance';
import { MotionTokens } from './MotionTokens';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import {
  DividerShowType,
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleMode,
  IconStyleMode,
  TextStyleMode,
  hdsMaterial
} from '@kit.UIDesignKit';

export interface UpdateChangelogEntry {
  versionName: string;
  versionCode: number;
  releaseDate: string;
  changes: string[];
  current: boolean;
}

/**
 * Release notes presented as a compact bottom sheet. The parent owns
 * visibility and persistence; this component only owns the selected release
 * while the user browses the notes.
 */
@Component
export struct UpdateChangelogSheet {
  @Prop entries: UpdateChangelogEntry[] = [];
  @Prop appName: string = 'MeshArc';
  @Prop glowLevel: number = 3;
  @Prop materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;

  @State private selectedIndex: number = 0;
  private detailsSwiperController: SwiperController = new SwiperController();

  private selectVersion(index: number): void {
    if (index < 0 || index >= this.entries.length || index === this.selectedIndex) {
      return;
    }
    this.selectedIndex = index;
    this.detailsSwiperController.changeIndex(index, true);
  }

  private requestAction(action: string): void {
    AppStorage.setOrCreate('updateChangelogAction', action);
  }

  @Builder
  private VersionTimelineItem(entry: UpdateChangelogEntry, index: number) {
    Column({ space: 5 }) {
      Stack() {
        Row()
          .width('100%')
          .height(2)
          .backgroundColor($r('sys.color.comp_divider'))
        Row()
          .width(index === this.selectedIndex ? 14 : 10)
          .height(index === this.selectedIndex ? 14 : 10)
          .borderRadius(index === this.selectedIndex ? 7 : 5)
          .backgroundColor(index === this.selectedIndex ? $r('app.color.emphasize') :
            $r('sys.color.icon_secondary'))
          .align(Alignment.Start)
      }
      .width('100%')
      .height(16)

      Text(`v${entry.versionName}`)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(index === this.selectedIndex ? $r('app.color.selection_foreground') :
          $r('sys.color.font_primary'))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 7, right: 7, top: 6, bottom: 6 })
        .backgroundColor(index === this.selectedIndex ? $r('app.color.selection_background') :
          $r('sys.color.background_primary'))
        .borderRadius(17)

      Text($r('app.string.update_changelog_timeline_code', entry.versionCode))
        .fontSize(UiTokens.CAPTION_SIZE)
        .fontColor(index === this.selectedIndex ? $r('app.color.emphasize') :
          $r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(entry.releaseDate)
        .fontSize(UiTokens.CAPTION_SIZE)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(126)
    .padding({ left: 2, right: 2 })
    .onClick(() => this.selectVersion(index))
  }

  @Builder
  private VersionTimeline() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.entries, (entry: UpdateChangelogEntry, index: number) => {
          this.VersionTimelineItem(entry, index);
        }, (entry: UpdateChangelogEntry, index: number) => `${entry.versionCode}-${index}`)
      }
      .padding({ left: 8, right: 8 })
    }
    .id('update-changelog-timeline')
    .width('100%')
    .height(116)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .backgroundColor($r('app.color.surface_subtle'))
    .borderRadius(20)
    .padding({ top: 11, bottom: 8 })
  }

  @Builder
  private ChangeRow(change: string) {
    Row({ space: 8 }) {
      Text('\u2022')
        .fontSize(17)
        .fontColor($r('app.color.emphasize'))
        .width(11)
        .textAlign(TextAlign.Center)
      Text(change)
        .fontSize(UiTokens.BODY_SIZE)
        .lineHeight(22)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private ChangelogDetails(entry: UpdateChangelogEntry) {
    Scroll() {
      Column({ space: UiTokens.GROUP_GAP }) {
        Text(`${this.appName} ${entry.versionName}`)
          .fontSize(UiTokens.TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')

        Text($r('app.string.update_changelog_detail_code', entry.versionCode))
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')

        Text(entry.releaseDate)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')

        Text($r('app.string.update_changelog_section'))
          .fontSize(UiTokens.SECTION_TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .margin({ top: 5 })

        ForEach(entry.changes, (change: string, index: number) => {
          this.ChangeRow(change);
        }, (_change: string, index: number) => `${entry.versionCode}-${index}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ left: 4, right: 4, bottom: 18 })
    }
    .id(`update-changelog-content-${entry.versionCode}`)
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private ChangelogPages() {
    if (this.entries.length > 0) {
      Swiper(this.detailsSwiperController) {
        ForEach(this.entries, (entry: UpdateChangelogEntry, index: number) => {
          this.ChangelogDetails(entry);
        }, (entry: UpdateChangelogEntry, index: number) => `${entry.versionCode}-${index}`)
      }
      .id('update-changelog-pages')
      .index(this.selectedIndex)
      .indicator(false)
      .loop(false)
      .duration(MotionTokens.NORMAL)
      .onChange((index: number) => this.selectedIndex = index)
      .layoutWeight(1)
      .width('100%')
    } else {
      Column() {
        Text($r('app.string.update_changelog_title'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    HdsNavigation() {
      Column({ space: UiTokens.GROUP_GAP }) {
        this.VersionTimeline()
        this.ChangelogPages()
      }
        .width('100%')
        .height('100%')
        .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 8, bottom: 16 })
        .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
    }
      .titleMode(HdsNavigationTitleMode.MODAL)
      .titleBar({
        enableComponentSafeArea: true,
        style: {
          blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
          originalStyle: {
            contentStyle: {
              titleStyle: {
                mainTitleColor: $r('sys.color.font_primary'),
                subTitleColor: $r('sys.color.font_secondary')
              },
              menuStyle: {
                iconColor: $r('sys.color.icon_primary'),
                textColor: $r('sys.color.font_primary')
              }
            }
          },
          systemMaterialEffect: {
            materialType: LightAppearance.hdsType(this.glowLevel),
            materialLevel: LightAppearance.hdsLevel(this.glowLevel)
          }
        },
        content: {
          title: { mainTitle: $r('app.string.update_changelog_title') },
          menu: {
            value: [{
              content: {
                label: $r('app.string.update_changelog_only_on_update'),
                type: TextStyleMode.NORMAL,
                isEnabled: true,
                action: () => this.requestAction('only_on_update')
              }
            }, {
              content: {
                label: $r('app.string.native_settings_close'),
                icon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
                  .fontColor([$r('sys.color.icon_primary')]),
                type: IconStyleMode.SMALL,
                isEnabled: true,
                action: () => this.requestAction('dismiss')
              }
            }]
          },
          divider: { showType: DividerShowType.OFF }
        }
      })
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      .id('update-changelog-navigation')
  }
}
