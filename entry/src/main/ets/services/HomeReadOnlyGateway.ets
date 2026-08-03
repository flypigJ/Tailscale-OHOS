import nativeBridge from 'libtailscale_ohos.so';

/**
 * Owns only Home's read operations. Connection commands and VPN lifecycle
 * handling stay with their existing owner until their dedicated milestone.
 */
export class HomeReadOnlyGateway {
  async readBackendSnapshot<T>(): Promise<T> {
    return JSON.parse(await nativeBridge.backendSnapshot()) as T;
  }

  readPeers<T>(): T {
    return JSON.parse(nativeBridge.backendPeers()) as T;
  }

  readAccount<T>(): T {
    return JSON.parse(nativeBridge.backendAccount()) as T;
  }
}

/** Rejects a completed read that belongs to an earlier Home lifecycle. */
export class HomeReadOnlyRequestGuard {
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

export interface HomeTrafficStatus {
  session: number;
  uploadBytes: number;
  downloadBytes: number;
}

/** Parses the read-only VPN status fields displayed by Home. */
export function parseHomeTrafficStatus(status: string): HomeTrafficStatus {
  return {
    session: statusNumber(status, 'trafficSession'),
    uploadBytes: statusNumber(status, 'txBytes'),
    downloadBytes: statusNumber(status, 'rxBytes')
  };
}

function statusNumber(status: string, key: string): number {
  const match: RegExpMatchArray | null = status.match(new RegExp(`(?:^|\\|\\s*)${key}=(\\d+)`));
  return match === null ? 0 : Number(match[1]);
}
