import { BridgeStatus } from './BridgeStatus';

/** M7 shell: Index creates one stable feature host; tabs never recreate it. */
@Component
export struct AppShell {
  build() {
    Column() {
      BridgeStatus()
    }
    .id('app-shell-edge-to-edge')
    .width('100%')
    .height('100%')
  }
}
