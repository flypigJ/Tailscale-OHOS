/**
 * Keeps the original connected-home composition intact.  Its two builders are
 * the pre-existing connected card (including totals/chart) and exit-node card.
 */
@Component
export struct LegacyConnectedHomeHeader {
  @BuilderParam connectionPanel: () => void;
  @BuilderParam exitNodePanel: () => void;

  build() {
    Column({ space: 12 }) {
      this.connectionPanel()
      this.exitNodePanel()
    }
    .width('100%')
  }
}
