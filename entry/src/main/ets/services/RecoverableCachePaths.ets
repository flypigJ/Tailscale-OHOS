import { common } from '@kit.AbilityKit';

const TAILDROP_OUTBOX_DIR_NAME: string = 'taildrop-outbox';

/**
 * M9C path boundary for files that are disposable copies of user-selected
 * content. Authoritative tsnet state, IPC, history, and inbox exports stay in
 * filesDir and are intentionally absent from this adapter.
 */
export class RecoverableCachePaths {
  static taildropOutboxRoot(context: common.Context): string {
    return `${context.cacheDir}/${TAILDROP_OUTBOX_DIR_NAME}`;
  }

  static legacyTaildropOutboxRoot(context: common.Context): string {
    return `${context.filesDir}/${TAILDROP_OUTBOX_DIR_NAME}`;
  }

  static isTaildropOutboxRoot(context: common.Context, path: string): boolean {
    return path === RecoverableCachePaths.taildropOutboxRoot(context) ||
      path === RecoverableCachePaths.legacyTaildropOutboxRoot(context);
  }
}
