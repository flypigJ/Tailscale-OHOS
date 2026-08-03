import {
  ConnectionPathType as CommonConnectionPathType,
  PeerPathResult as CommonPeerPathResult,
  serializePeerPathResult as serializeCommonPeerPathResult
} from '@tailscale/common';

export type SunshineState = 'unknown' | 'checking' | 'available' | 'unavailable' | 'timeout' | 'error';

/** M1 compatibility adapter: existing Entry imports keep their contract. */
export type ConnectionPathType = CommonConnectionPathType;

export interface SunshineProbeResult {
  state: SunshineState;
  checkedAt: number;
  latencyMs?: number;
  serverName?: string;
  serverVersion?: string;
  errorMessage?: string;
}

export type PeerPathResult = CommonPeerPathResult;

/** M1 compatibility adapter for the pre-existing plain-object JSON contract. */
export function serializePeerPathResult(value: PeerPathResult): string {
  return serializeCommonPeerPathResult(value);
}

export interface StreamLaunchProfile {
  profileName: 'default' | 'peer_relay' | 'relay_safe';
  recommendedBitrateKbps?: number;
  recommendedWidth?: number;
  recommendedHeight?: number;
  recommendedFps?: number;
  allowUserOverride: boolean;
}

export interface MoonlightLaunchRequest {
  protocolVersion: number;
  action: 'openHost';
  source: 'MeshArc';
  host: string;
  displayName: string;
  dnsName?: string;
  pathType: ConnectionPathType;
  relayRegion?: string;
  latencyMs?: number;
  streamProfile: StreamLaunchProfile;
}
