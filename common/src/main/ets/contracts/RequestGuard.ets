/**
 * Framework-free async lifecycle generation guards.
 *
 * - RequestGuard: latest-wins exclusive guard; each begin() increments generation
 *   so only the most recent in-flight operation remains current.
 * - EpochRequestGuard: shared-epoch read guard; begin() returns the current epoch
 *   without incrementing so concurrent read-only queries stay valid until invalidate().
 */

export class RequestGuard {
  private generation: number = 0;

  begin(): number {
    this.generation++;
    return this.generation;
  }

  invalidate(): void {
    this.generation++;
  }

  isCurrent(generation: number): boolean {
    return generation > 0 && generation === this.generation;
  }
}

export class EpochRequestGuard {
  private generation: number = 0;

  begin(): number {
    return this.generation;
  }

  invalidate(): void {
    this.generation++;
  }

  isCurrent(generation: number): boolean {
    return generation === this.generation;
  }
}

export {
  RequestGuard as AccountDiagnosticsRequestGuard,
  RequestGuard as SettingsRequestGuard,
  EpochRequestGuard as HomeReadOnlyRequestGuard
};
