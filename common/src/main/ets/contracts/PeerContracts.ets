/** Framework-free peer, account, exit-node, and LocalSend/MeshArc receiver contracts. */

export interface LocalSendStatus {
  state: string;
  protocol?: string;
  port?: number;
  version?: string;
  checkedAtMs?: number;
}

export interface PeerSummary {
  key: string;
  name: string;
  os: string;
  osVersion?: string;
  deviceModel: string;
  deviceType: string;
  addresses: string[];
  online: boolean;
  exitNode: boolean;
  keyExpired: boolean;
  keyExpiryUnixMs: number;
  localSend?: LocalSendStatus;
}

export interface AccountSummary {
  displayName: string;
  loginName: string;
  profilePicURL: string;
  tailnetName: string;
  deviceName: string;
  addresses: string[];
  needsApproval: boolean;
  keyExpired: boolean;
  keyExpiryUnixMs: number;
}

export interface MeshArcReceiverStatus {
  state: string;
  protocol?: string;
  httpStatus?: number;
  sent: number;
  registered: number;
  httpsReason?: string;
  httpReason?: string;
  checkedAtMs?: number;
}

export interface PersistedPeerSnapshot {
  peers: PeerSummary[];
  meshArcReceiver?: MeshArcReceiverStatus;
  account?: AccountSummary;
  updatedAtMs: number;
}

export interface ExitNodeChoice {
  id: string;
  name: string;
  online: boolean;
  selected: boolean;
}

export interface NetworkSettings {
  routeAll: boolean;
  exitNodeAllowLANAccess: boolean;
}

export function emptyMeshArcReceiverStatus(): MeshArcReceiverStatus {
  const status: MeshArcReceiverStatus = { state: 'idle', sent: 0, registered: 0 };
  return status;
}
