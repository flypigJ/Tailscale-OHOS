/** Framework-free connection-path contract. */
export type ConnectionPathType = 'direct' | 'peerRelay' | 'derp' | 'unknown' | 'unreachable';

export interface PeerPathResult {
  type: ConnectionPathType;
  latencyMs?: number;
  relayRegion?: string;
  checkedAt: number;
  errorMessage?: string;
}

/** Preserves the Entry adapter's plain-object JSON property order. */
export function serializePeerPathResult(value: PeerPathResult): string {
  return JSON.stringify(value);
}
