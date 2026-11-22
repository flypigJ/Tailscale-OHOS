import { HomeTrafficStatus, parseHomeTrafficStatus } from './HomeReadOnlyGateway';

const MAX_SAMPLES: number = 30;
const FRESH_MS: number = 5000;

export interface PipTrafficRate {
  down: number;
  up: number;
}

/** A read-only view of the current VPN session's rate history. */
export class PipTrafficHistory {
  private previous?: HomeTrafficStatus;
  private previousMs: number = 0;
  private rates: PipTrafficRate[] = [];

  // Undefined means the existing UI does not need to redraw.
  update(status: string, now: number): PipTrafficRate[] | undefined {
    const clock: RegExpMatchArray | null = status.match(/(?:^|\|\s*)heartbeatMs=(\d+)/);
    const at: number = clock === null ? 0 : Number(clock[1]);
    const traffic: HomeTrafficStatus = parseHomeTrafficStatus(status);
    if (at <= 0 || at > now || now - at > FRESH_MS || !status.includes('state=Running') ||
      !status.includes('tun=true') || traffic.session <= 0 || !/(?:^|\|\s*)rxBytes=\d+/.test(status) ||
      !/(?:^|\|\s*)txBytes=\d+/.test(status)) {
      this.previous = undefined;
      this.previousMs = 0;
      if (this.rates.length === 0) return undefined;
      this.rates = [];
      return [];
    }
    const previous: HomeTrafficStatus | undefined = this.previous;
    if (previous !== undefined && previous.session === traffic.session && this.previousMs === at) return undefined;
    const elapsed: number = at - this.previousMs;
    this.previous = traffic;
    this.previousMs = at;
    if (previous === undefined || previous.session !== traffic.session || elapsed <= 0 || elapsed > FRESH_MS ||
      traffic.downloadBytes < previous.downloadBytes || traffic.uploadBytes < previous.uploadBytes) {
      const hadRates: boolean = this.rates.length > 0;
      this.rates = [];
      return hadRates ? [] : undefined;
    }
    this.rates.push({ down: (traffic.downloadBytes - previous.downloadBytes) * 1000 / elapsed,
      up: (traffic.uploadBytes - previous.uploadBytes) * 1000 / elapsed });
    if (this.rates.length > MAX_SAMPLES) this.rates.shift();
    return this.rates.slice();
  }
}

export function pipTrafficPoints(rates: PipTrafficRate[], download: boolean): number[][] {
  let max: number = 1;
  for (const rate of rates) max = Math.max(max, rate.down, rate.up);
  if (rates.length === 0) return [];
  if (rates.length === 1) {
    const y: number = 48 - (download ? rates[0].down : rates[0].up) / max * 46;
    return [[96, y], [98, y]];
  }
  return rates.map((rate: PipTrafficRate, i: number): number[] => [
    2 + (MAX_SAMPLES - rates.length + i) * 96 / (MAX_SAMPLES - 1),
    48 - (download ? rate.down : rate.up) / max * 46
  ]);
}

export function formatPipTrafficRate(value: number | undefined): string {
  if (value === undefined) return '—';
  if (value < 1024) return `${Math.round(value)} B/s`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB/s`;
  return `${(value / (1024 * 1024)).toFixed(1)} MiB/s`;
}
