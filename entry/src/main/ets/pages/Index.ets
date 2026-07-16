import { BridgeStatus } from '../components/BridgeStatus';

@Entry
@Component
struct Index {
  build() {
    Column() {
      BridgeStatus()
    }
    .width('100%')
    .height('100%')
  }
}
