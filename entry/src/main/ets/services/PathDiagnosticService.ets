import { fileIo } from '@kit.CoreFileKit';
import { connection } from '@kit.NetworkKit';
import nativeBridge from 'libtailscale_ohos.so';
import { AtomicFileStore } from './AtomicFileStore';

interface PathRequest { requestId: number; createdMs: number; action: string; }
interface PathReply { requestId: number; result: string; active: boolean; }
interface PathEvent {
  seq: number; timestampMs: number; elapsedMs: number; networkEpoch: number;
  socketEpoch?: number; kind: string; result: string; family?: number;
  peer?: string; endpoint?: string; tx?: string; errno?: number; n?: number[];
}
interface PathCounter { kind: string; result: string; count: number; }
interface PathCoverage { kind: string; state: string; count: number; }
interface PathTrace {
  coverage: PathCoverage[];
  schema: number; session: string; active: boolean; startedMs: number; deadlineMs: number;
  stoppedMs: number; stopReason: string; networkEpoch: number; capacity: number;
  overwritten: number; rateDropped: number; contentionDropped: number; invalidDropped: number;
  sampledOut: number; counters: PathCounter[]; events: PathEvent[]; missing: string[];
}
interface PathEnvelope {
  schema: number; result: string; buildSource: string; core: string; go: string;
  exportedMs: number; trace: PathTrace;
}

const PATH_REQUEST: string = '/path-diagnostic-request.json';
const PATH_REPLY: string = '/path-diagnostic-reply.json';
const PATH_TRACE: string = '/path-diagnostic-trace.json';
const MAX_TRACE_BYTES: number = 1024 * 1024;
const ACTIONS: string[] = ['start', 'stop', 'snapshot', 'probe', 'clear'];
const KINDS: string[] = ['capture', 'host_network', 'host_protection', 'host_monitor', 'socket_bind',
  'socket_rebind', 'socket_snapshot', 'receive_loop', 'udp_receive', 'udp_write', 'stun_send',
  'stun_receive', 'restun', 'netcheck', 'netcheck_cache', 'disco_send', 'disco_receive', 'disco_drop',
  'ping', 'pong', 'endpoint', 'data_path', 'active_probe'];
const RESULTS: string[] = ['start', 'stop', 'expired', 'cleared', 'replaced', 'requested', 'queued',
  'coalesced', 'closed', 'stopped', 'offline', 'unavailable', 'unknown', 'ok', 'error', 'suppressed',
  'udp4', 'udp6', 'derp', 'peer_relay', 'direct', 'disco', 'stun', 'wireguard', 'unknown_peer',
  'unknown_relay', 'no_key', 'decrypt_failed', 'decrypted', 'parse_failed', 'parsed', 'invalid_transport',
  'unknown_txid', 'expired_txid', 'endpoint_removed', 'matched', 'candidate', 'promoted', 'retained', 'ping', 'pong',
  'call_me_maybe', 'other', 'timeout', 'busy', 'rate_limited', 'cancelled', 'skipped', 'complete',
  'not_selected', 'no_derp_map', 'wrong_family', 'truncated', 'protected', 'fallback', 'wifi',
  'cellular', 'pending', 'network_changed', 'stale', 'failed', 'observed', 'never_started'];

// Both processes use the existing application-private filesDir IPC. Only the VPN
// process handles native commands; a UI-process backend cannot impersonate it.
export class PathDiagnosticService {
  private static processing: boolean = false;
  private static closing: boolean = false;
  private static lifecycleRevision: number = 0;
  private static requesting: boolean = false;
  private static captureUntilMs: number = 0;
  private static nextSnapshotMs: number = 0;
  private static hostInFlight: boolean = false;
  private static hostSequence: number = 0;
  private static requestSequence: number = 0;

  static async request(filesDir: string, action: string): Promise<string> {
    if (!ACTIONS.includes(action) || PathDiagnosticService.requesting) {
      return 'busy';
    }
    PathDiagnosticService.requesting = true;
    const id: number = Math.max(Date.now(), PathDiagnosticService.requestSequence + 1);
    PathDiagnosticService.requestSequence = id;
    try {
      const request: PathRequest = { requestId: id, createdMs: Date.now(), action: action };
      PathDiagnosticService.writeAtomic(filesDir + PATH_REQUEST, JSON.stringify(request));
      for (let attempt: number = 0; attempt < 80; attempt++) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        try {
          const text: string = PathDiagnosticService.readLimited(filesDir + PATH_REPLY, 1024);
          const reply: PathReply = JSON.parse(text) as PathReply;
          if (reply.requestId === id) {
            return PathDiagnosticService.safeResult(reply.result);
          }
        } catch (_error) {}
      }
      return 'vpn_unavailable_or_timeout';
    } catch (_error) {
      return 'request_failed';
    } finally {
      PathDiagnosticService.requesting = false;
    }
  }

  // Invoked by the existing VPN request timer; one worker, one command, no queue.
  static poll(filesDir: string, protection: number, protectionCode: number = 0): void {
    if (PathDiagnosticService.closing || PathDiagnosticService.processing) { return; }
    let request: PathRequest | undefined = undefined;
    try {
      const text: string = PathDiagnosticService.readLimited(filesDir + PATH_REQUEST, 1024);
      if (text.length > 0) {
        PathDiagnosticService.writeAtomic(filesDir + PATH_REQUEST, '');
        const candidate: PathRequest = JSON.parse(text) as PathRequest;
        if (Number.isSafeInteger(candidate.requestId) && candidate.requestId > 0 &&
          Date.now() >= candidate.createdMs && Date.now() - candidate.createdMs <= 7000 &&
          ACTIONS.includes(candidate.action)) { request = candidate; }
      }
    } catch (_error) {}
    if (request === undefined && (PathDiagnosticService.captureUntilMs === 0 ||
      Date.now() < PathDiagnosticService.nextSnapshotMs)) { return; }
    PathDiagnosticService.processing = true;
    PathDiagnosticService.process(filesDir, protection, protectionCode, request).finally(() => {
      PathDiagnosticService.processing = false;
    });
  }

  private static async process(filesDir: string, protection: number, protectionCode: number,
    request?: PathRequest): Promise<void> {
    const revision: number = PathDiagnosticService.lifecycleRevision;
    const action: string = request?.action ?? 'snapshot';
    let result: string = 'native_unavailable';
    let active: boolean = false;
    try {
      const command: string = JSON.stringify({ action: action, seconds: 180 });
      const nativeText: string = await nativeBridge.backendPathDiagnosticAsync(command);
      if (revision !== PathDiagnosticService.lifecycleRevision || PathDiagnosticService.closing) { return; }
      let safeText: string = PathDiagnosticService.sanitize(nativeText);
      let envelope: PathEnvelope = JSON.parse(safeText) as PathEnvelope;
      result = envelope.result;
      active = envelope.trace.active;
      PathDiagnosticService.captureUntilMs = active ? envelope.trace.deadlineMs : 0;
      if (action === 'start' && active) {
        await PathDiagnosticService.recordHost(protection, 0, 0, 0, 0, protectionCode);
        safeText = PathDiagnosticService.sanitize(
          await nativeBridge.backendPathDiagnosticAsync('{"action":"snapshot"}'));
      }
      if (revision !== PathDiagnosticService.lifecycleRevision || PathDiagnosticService.closing) { return; }
      PathDiagnosticService.writeAtomic(filesDir + PATH_TRACE, safeText);
      PathDiagnosticService.nextSnapshotMs = Date.now() + 10000;
    } catch (_error) {
      result = 'snapshot_store_failed';
      PathDiagnosticService.nextSnapshotMs = Date.now() + 10000;
    }
    if (request !== undefined) {
      const reply: PathReply = { requestId: request.requestId, result: result, active: active };
      try { PathDiagnosticService.writeAtomic(filesDir + PATH_REPLY, JSON.stringify(reply)); } catch (_error) {}
    }
  }

  static async recordHost(protection: number, stage: number, generation: number,
    revision: number, code: number = 0, protectionCode: number = 0): Promise<void> {
    if (Date.now() >= PathDiagnosticService.captureUntilMs || PathDiagnosticService.hostInFlight) { return; }
    PathDiagnosticService.hostInFlight = true;
    const sequence: number = ++PathDiagnosticService.hostSequence;
    const deadline: number = PathDiagnosticService.captureUntilMs;
    try {
      await Promise.race([PathDiagnosticService.readHost(protection, stage, generation, revision, code,
        protectionCode, sequence, deadline), new Promise<void>((resolve: () => void) => setTimeout(resolve, 1500))]);
    } finally { PathDiagnosticService.hostInFlight = false; }
  }

  private static async readHost(protection: number, stage: number, generation: number, revision: number,
    code: number, protectionCode: number, sequence: number, deadline: number): Promise<void> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      let name: string = '';
      let bearer: number = 3;
      let v4: number = 0;
      let v6: number = 0;
      if (net.netId > 0) {
        const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
        const current: connection.NetHandle = await connection.getDefaultNet();
        if (current.netId !== net.netId) { return; }
        name = props.interfaceName;
        bearer = caps.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ? 2 :
          caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ? 1 : 0;
        (props.linkAddresses ?? []).forEach((link: connection.LinkAddress) => {
          if (link.address.address.includes(':')) { v6++; } else { v4++; }
        });
      }
      if (sequence !== PathDiagnosticService.hostSequence || deadline !== PathDiagnosticService.captureUntilMs ||
        Date.now() >= deadline) { return; }
      await nativeBridge.backendPathDiagnosticAsync(JSON.stringify({ action: 'host', netId: net.netId,
        interface: name, bearer: bearer, ipv4Count: v4, ipv6Count: v6, protection: protection, protectionCode: protectionCode,
        stage: stage, generation: generation, revision: revision, code: code }));
    } catch (_error) {
      if (sequence !== PathDiagnosticService.hostSequence || deadline !== PathDiagnosticService.captureUntilMs || Date.now() >= deadline) { return; }
      // Unknown fields remain explicit -1; never retain platform error text.
      try { await nativeBridge.backendPathDiagnosticAsync(JSON.stringify({ action: 'host',
        netId: -1, ipv4Count: -1, ipv6Count: -1, protection: protection, protectionCode: protectionCode, stage: -1, code: -1 })); } catch (_nativeError) {}
    }
  }

  // Rebuild an allowlisted document rather than trusting raw logs or extra JSON
  // properties. Reject malformed/truncated/oversized snapshots as a whole.
  static sanitize(text: string): string {
    if (text.length > MAX_TRACE_BYTES) { throw new Error('trace_limit'); }
    const source: PathEnvelope = JSON.parse(text) as PathEnvelope;
    const trace: PathTrace = source.trace;
    if (source.schema !== 1 || trace.schema !== 1 || !Array.isArray(trace.events) ||
      trace.events.length > 1536 || !/^(?:[a-f0-9]{16})?$/.test(trace.session ?? '') ||
      !/^(?:[a-f0-9]{64}|working-tree-unrecorded)$/.test(source.buildSource) ||
      source.core !== '1.104.5' || !/^go[0-9.]+$/.test(source.go)) { throw new Error('trace_schema'); }
    const events: PathEvent[] = trace.events.map((event: PathEvent): PathEvent => {
      if (!KINDS.includes(event.kind) || !RESULTS.includes(event.result) ||
        ![0, 4, 6].includes(event.family ?? 0) || (event.n ?? []).length > 8) { throw new Error('event_schema'); }
      return { seq: PathDiagnosticService.number(event.seq), timestampMs: PathDiagnosticService.number(event.timestampMs),
        elapsedMs: PathDiagnosticService.number(event.elapsedMs), networkEpoch: PathDiagnosticService.number(event.networkEpoch),
        socketEpoch: PathDiagnosticService.number(event.socketEpoch ?? 0), kind: event.kind, result: event.result,
        family: event.family ?? 0, peer: PathDiagnosticService.alias(event.peer), endpoint: PathDiagnosticService.alias(event.endpoint),
        tx: PathDiagnosticService.alias(event.tx), errno: PathDiagnosticService.number(event.errno ?? 0),
        n: (event.n ?? []).map((value: number) => PathDiagnosticService.number(value)) };
    });
    const safe: PathEnvelope = { schema: 1, result: PathDiagnosticService.safeResult(source.result),
      buildSource: source.buildSource, core: source.core, go: source.go,
      exportedMs: PathDiagnosticService.number(source.exportedMs), trace: {
        coverage: (trace.coverage ?? []).slice(0, 24).map((item: PathCoverage): PathCoverage => {
          if (!KINDS.includes(item.kind) || !['observed', 'observed_zero', 'not_captured', 'unknown_due_to_drops'].includes(item.state)) { throw new Error('coverage_schema'); }
          return { kind: item.kind, state: item.state, count: PathDiagnosticService.number(item.count) };
        }),
        schema: 1, session: trace.session ?? '', active: trace.active === true,
        startedMs: PathDiagnosticService.number(trace.startedMs), deadlineMs: PathDiagnosticService.number(trace.deadlineMs),
        stoppedMs: PathDiagnosticService.number(trace.stoppedMs), stopReason: RESULTS.includes(trace.stopReason) ? trace.stopReason : 'unknown',
        networkEpoch: PathDiagnosticService.number(trace.networkEpoch), capacity: 1536,
        overwritten: PathDiagnosticService.number(trace.overwritten), rateDropped: PathDiagnosticService.number(trace.rateDropped),
        contentionDropped: PathDiagnosticService.number(trace.contentionDropped), invalidDropped: PathDiagnosticService.number(trace.invalidDropped),
        sampledOut: PathDiagnosticService.number(trace.sampledOut),
        counters: (trace.counters ?? []).slice(0, 1536).map((counter: PathCounter): PathCounter => {
          if (!KINDS.includes(counter.kind) || !RESULTS.includes(counter.result)) { throw new Error('counter_schema'); }
          return { kind: counter.kind, result: counter.result, count: PathDiagnosticService.number(counter.count) };
        }), events: events,
        missing: (trace.missing ?? []).filter((value: string) => [
          'kernel_egress_not_observed', 'remote_delivery_not_observed', 'per_socket_nethandle_binding_not_used',
          'raw_payload_not_collected', 'addresses_and_keys_not_collected', 'capture_not_started',
          'netcheck_not_observed_in_capture', 'socket_bind_not_observed_in_capture',
          'disco_receive_not_observed_in_capture', 'pong_not_observed_in_capture'].includes(value))
      } };
    // Per-kind totals include rate-limited/sampled observations; contention is
    // explicitly counted separately because the recording path never waits.
    const result: string = JSON.stringify(safe);
    if (result.length > MAX_TRACE_BYTES) { throw new Error('trace_limit'); }
    return result;
  }

  static exportSnapshot(filesDir: string): string {
    try {
 const text: string = PathDiagnosticService.sanitize(PathDiagnosticService.readLimited(filesDir + PATH_TRACE, MAX_TRACE_BYTES));
 const envelope: PathEnvelope = JSON.parse(text) as PathEnvelope;
 if (Date.now() - envelope.exportedMs > 24 * 60 * 60 * 1000 || envelope.exportedMs > Date.now() + 5000) { throw new Error('capture_expired'); }
 return text;
 }
    catch (_error) { return '{"schema":1,"result":"unavailable","missing":["capture_not_available_or_invalid"]}'; }
  }

  static resume(): void {
    PathDiagnosticService.closing = false;
    PathDiagnosticService.lifecycleRevision++;
    PathDiagnosticService.captureUntilMs = 0;
  }

  static async shutdown(filesDir: string): Promise<void> {
    PathDiagnosticService.closing = true;
    PathDiagnosticService.lifecycleRevision++;
    PathDiagnosticService.captureUntilMs = 0;
    try {
      const text: string = await nativeBridge.backendPathDiagnosticAsync('{"action":"stop"}');
      PathDiagnosticService.writeAtomic(filesDir + PATH_TRACE, PathDiagnosticService.sanitize(text));
    } catch (_error) {}
  }

  private static alias(value?: string): string {
    if (value === undefined || value === '') { return ''; }
    if (!/^[a-f0-9]{24}$/.test(value)) { throw new Error('invalid_alias'); }
    return value;
  }
  private static number(value: number): number { return Number.isSafeInteger(value) ? value : -1; }
  private static safeResult(value: string): string {
    return ['ok', 'invalid_command', 'vpn_unavailable', 'random_unavailable', 'capture_disabled',
      'probe_busy', 'probe_rate_limited', 'probe_started', 'serialization_failed',
      'native_unavailable', 'snapshot_store_failed'].includes(value) ? value : 'unknown';
  }
  private static readLimited(path: string, maximum: number): string {
    if (!fileIo.accessSync(path)) { return ''; }
    if (fileIo.statSync(path).size > maximum) { throw new Error('file_limit'); }
    return fileIo.readTextSync(path);
  }
  private static writeAtomic(path: string, text: string): void {
    AtomicFileStore.writeAtomicOrThrow(path, text, {
      owner: 'path-diag',
      fsync: false
    });
  }
}
