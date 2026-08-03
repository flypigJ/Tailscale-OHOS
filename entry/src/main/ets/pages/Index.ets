import { AppShell } from '../components/AppShell';

@Entry
@Component
struct Index {
  build() {
    Column() {
      AppShell()
    }
    .id('shell-window-host')
    .width('100%')
    .height('100%')
  }
}
