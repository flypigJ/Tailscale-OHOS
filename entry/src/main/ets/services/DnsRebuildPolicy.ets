// Bound automatic DNS plan transitions. A changed policy starts a fresh failure
// budget, while a global cooldown prevents control updates from flapping TUNs.
export class DnsRebuildPolicy {
  private key: string = '';
  private failures: number = 0;
  private active: boolean = false;
  private nextAttemptMs: number = 0;

  begin(key: string, now: number): boolean {
    if (this.active || now < this.nextAttemptMs) return false;
    if (key !== this.key) { this.key = key; this.failures = 0; }
    if (this.failures >= 2) return false;
    this.active = true;
    this.nextAttemptMs = now + 30000;
    return true;
  }

  finish(succeeded: boolean): void {
    if (!this.active) return;
    this.active = false;
    if (succeeded) this.failures = 0;
    else this.failures++;
  }
}
