/** Framework-free cross-process VPN Extension IPC file names and control DTOs. */

export const VPN_PROBE_STATUS_FILE_NAME: string = 'vpn-probe-status.txt';
export const VPN_PEERS_FILE_NAME: string = 'vpn-peers.json';
export const VPN_STOP_REQUEST_FILE_NAME: string = 'vpn-stop-request.json';
export const VPN_STOP_RESPONSE_FILE_NAME: string = 'vpn-stop-response.json';
export const VPN_CONFIG_SUMMARY_FILE_NAME: string = 'vpn-config-summary.txt';
export const VPN_CONNECT_CONFIG_FILE_NAME: string = 'vpn-connect-config.json';
export const VPN_REPLACE_APPROVAL_FILE_NAME: string = 'vpn-replace-approved';
export const VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME: string = 'vpn-backend-handoff-request.json';
export const VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME: string = 'vpn-backend-handoff-response.json';

export const LOCAL_SEND_REFRESH_REQUEST_FILE_NAME: string = 'localsend-refresh-request.json';
export const LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME: string = 'localsend-refresh-response.json';

export const PEER_CONNECTIVITY_REQUEST_FILE_NAME: string = 'peer-connectivity-request.json';
export const PEER_CONNECTIVITY_RESPONSE_FILE_NAME: string = 'peer-connectivity-response.json';
export const SUNSHINE_PROBE_REQUEST_FILE_NAME: string = 'sunshine-probe-request.json';
export const SUNSHINE_PROBE_RESPONSE_FILE_NAME: string = 'sunshine-probe-response.json';
export const MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME: string = 'media-service-probe-request.json';
export const MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME: string = 'media-service-probe-response.json';

export const TAILDROP_SEND_REQUEST_FILE_NAME: string = 'taildrop-send-request.json';
export const TAILDROP_TARGETS_FILE_NAME: string = 'taildrop-targets.json';
export const TAILDROP_CANCEL_REQUEST_FILE_NAME: string = 'taildrop-cancel-request.json';
export const TAILDROP_INBOX_DIR_NAME: string = 'taildrop-inbox-export';
export const TAILDROP_INBOX_SNAPSHOT_FILE_NAME: string = 'taildrop-inbox-snapshot.json';
export const TAILDROP_RECEIVE_REQUEST_FILE_NAME: string = 'taildrop-receive-request.json';
export const TAILDROP_RECEIVE_RESPONSE_FILE_NAME: string = 'taildrop-receive-response.json';
export const TAILDROP_HISTORY_FILE_NAME: string = 'taildrop-history.json';
export const TAILDROP_HISTORY_MEDIA_DIR_NAME: string = 'taildrop-history-media';

export const TAILDRIVE_QUERY_REQUEST_FILE_NAME: string = 'taildrive-query-request.json';
export const TAILDRIVE_QUERY_RESPONSE_FILE_NAME: string = 'taildrive-query-response.json';
export const TAILDRIVE_TRANSFER_REQUEST_FILE_NAME: string = 'taildrive-transfer-request.json';
export const TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME: string = 'taildrive-transfer-response.json';
export const TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME: string = 'taildrive-manual-transfer-request.json';
export const TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME: string = 'taildrive-manual-transfer-response.json';
export const TAILDRIVE_CONTROL_REQUEST_FILE_NAME: string = 'taildrive-control-request.json';
export const TAILDRIVE_CONTROL_RESPONSE_FILE_NAME: string = 'taildrive-control-response.json';

export const RPC_CHANNEL_FILE_NAMES: string[] = [
  PEER_CONNECTIVITY_REQUEST_FILE_NAME,
  PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
  SUNSHINE_PROBE_REQUEST_FILE_NAME,
  SUNSHINE_PROBE_RESPONSE_FILE_NAME,
  MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME,
  MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME,
  TAILDRIVE_QUERY_REQUEST_FILE_NAME,
  TAILDRIVE_QUERY_RESPONSE_FILE_NAME,
  TAILDRIVE_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME,
  TAILDRIVE_CONTROL_REQUEST_FILE_NAME,
  TAILDRIVE_CONTROL_RESPONSE_FILE_NAME
];

export interface VpnStopRequest {
  requestId: number;
}

export interface VpnStopResponse {
  requestId: number;
  status: string;
}

export interface VpnConnectConfigHandoff {
  createdAtMs: number;
  config: string;
}

export interface VpnBackendHandoffRequest {
  requestId: number;
}

export interface VpnBackendHandoffResponse {
  requestId: number;
  status: string;
}

export interface LocalSendRefreshRequest {
  requestId: number;
}

export interface LocalSendRefreshResponse {
  requestId: number;
  status: string;
}

export interface DnsSystemStatus {
  schemaVersion: number;
  state: string;
  systemDnsApplied: boolean;
  dnsAddressCount: number;
  searchDomainCount: number;
}
