/** Pure presentation rules. Empty content is not evidence that a feature is disabled. */
export interface TransferGuideContext {
  connected: boolean;
  refreshing: boolean;
  state: string;
  taildropTargets: number;
  busy: boolean;
}

export function transferGuideNotice(context: TransferGuideContext): string {
  if (context.busy) return '';
  if (!context.connected) return 'connect';
  if (context.refreshing || context.state === 'loading') return 'loading';
  if (context.state === 'disabled') return 'disabled';
  if (context.state === 'ready' && context.taildropTargets === 0) return 'targets';
  if (context.state === 'unavailable') return 'error';
  return context.state === 'ready' ? '' : 'loading';
}

export interface TaildriveGuideContext {
  connected: boolean;
  loading: boolean;
  busy: boolean;
  locked: boolean;
  reason: string;
  listFailure: boolean;
  path: string;
  listedPath: string;
  entryCount: number;
  search: string;
}

export function taildriveGuideNotice(context: TaildriveGuideContext): string {
  if (!context.connected || context.loading || context.busy || context.locked || context.search.trim().length > 0) return '';
  if (context.reason.length > 0) {
    return context.listFailure && context.reason === 'permission_denied' ? 'permission' : '';
  }
  const depth: number = context.path.split('/').filter((part: string) => part.length > 0).length;
  return context.listedPath === context.path && context.entryCount === 0 && depth < 3 ? 'share' : '';
}
