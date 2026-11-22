import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { formatPipTrafficRate, PipTrafficRate, pipTrafficPoints } from '../services/PipTrafficHistory';

class PipTrafficFrame {
  download: string;
  upload: string;
  downPoints: number[][];
  upPoints: number[][];

  constructor(rates: PipTrafficRate[]) {
    const latest: PipTrafficRate | undefined = rates[rates.length - 1];
    this.download = formatPipTrafficRate(latest?.down);
    this.upload = formatPipTrafficRate(latest?.up);
    this.downPoints = pipTrafficPoints(rates, true);
    this.upPoints = pipTrafficPoints(rates, false);
  }
}

@Builder
function buildPipTraffic($$: PipTrafficFrame) {
  Column({ space: 1 }) {
    Text(`↓ ${$$.download}`).fontSize(11).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.pip_traffic_download'))
      .maxLines(1).width('100%').textAlign(TextAlign.Start)
    Text(`↑ ${$$.upload}`).fontSize(11).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.pip_traffic_upload'))
      .maxLines(1).width('100%').textAlign(TextAlign.Start)
    Shape() {
      Polyline().points([[2, 48], [98, 48]]).stroke($r('app.color.pip_traffic_baseline')).strokeWidth(1)
      if ($$.downPoints.length > 0) {
        Polyline().points($$.downPoints).stroke($r('app.color.pip_traffic_download')).strokeWidth(2).fill(Color.Transparent)
        Polyline().points($$.upPoints).stroke($r('app.color.pip_traffic_upload')).strokeWidth(2).fill(Color.Transparent)
      }
    }
    .viewPort({ x: 0, y: 0, width: 100, height: 50 })
    .width('100%')
    .layoutWeight(1)
    .clip(true)
  }
  .width('100%')
  .height('100%')
  .padding({ top: 6, bottom: 5, left: 7, right: 7 })
  .backgroundColor($r('app.color.pip_traffic_surface'))
}

export class PipTrafficChart extends NodeController {
  private node?: BuilderNode<[PipTrafficFrame]>;
  private frame: PipTrafficFrame = new PipTrafficFrame([]);

  makeNode(context: UIContext): FrameNode | null {
    this.node?.dispose();
    const node: BuilderNode<[PipTrafficFrame]> = new BuilderNode(context);
    this.node = node;
    node.build(wrapBuilder<[PipTrafficFrame]>(buildPipTraffic), this.frame);
    return node.getFrameNode();
  }

  update(rates: PipTrafficRate[]): void {
    this.frame = new PipTrafficFrame(rates);
    this.node?.update(this.frame);
  }

  dispose(): void {
    this.node?.dispose();
    this.node = undefined;
  }
}
