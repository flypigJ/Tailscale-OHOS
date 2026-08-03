import { Want } from '@kit.AbilityKit';

export interface AppShellFeatureAction {
  openTaildropInbox: boolean;
  taildropNotificationAction: string;
}

/** M7 trust boundary for the existing external notification Want contract. */
export class AppShellIntentAdapter {
  private deliveredNotificationKeys: string[] = [];

  toFeatureAction(want: Want): AppShellFeatureAction {
    const openTaildropInbox: boolean = want.parameters?.taildropOpenInbox === true;
    const action: string | undefined = want.parameters?.taildropNotificationAction as string | undefined;
    const fileName: string | undefined = want.parameters?.taildropNotificationFileName as string | undefined;
    const size: number | undefined = want.parameters?.taildropNotificationFileSize as number | undefined;
    const suppliedReceivedAtMs: number | undefined =
      want.parameters?.taildropNotificationReceivedAtMs as number | undefined;
    const suppliedEventId: string | undefined = want.parameters?.taildropNotificationEventId as string | undefined;
    if (!this.isValidNotificationAction(action, fileName, size, suppliedReceivedAtMs, suppliedEventId)) {
      return { openTaildropInbox: openTaildropInbox, taildropNotificationAction: '' };
    }
    const eventId: string = suppliedEventId ?? `legacy:${fileName}:${size}`;
    const key: string = `${eventId}:${action}`;
    if (this.deliveredNotificationKeys.includes(key)) {
      return { openTaildropInbox: openTaildropInbox, taildropNotificationAction: '' };
    }
    this.deliveredNotificationKeys.push(key);
    if (this.deliveredNotificationKeys.length > 64) {
      this.deliveredNotificationKeys.shift();
    }
    return {
      openTaildropInbox: openTaildropInbox,
      taildropNotificationAction: JSON.stringify({
        action, fileName, size, receivedAtMs: suppliedReceivedAtMs ?? -1, eventId, atMs: Date.now()
      })
    };
  }

  private isValidNotificationAction(action: string | undefined, fileName: string | undefined,
    size: number | undefined, receivedAtMs: number | undefined, eventId: string | undefined): boolean {
    if (action !== 'open' && action !== 'save' && action !== 'later') {
      return false;
    }
    if (typeof fileName !== 'string' || fileName.length === 0 || fileName.length > 255 ||
      fileName === '.' || fileName === '..' || fileName.includes('/') || fileName.includes('\\') ||
      /[\u0000-\u001f]/.test(fileName)) {
      return false;
    }
    if (typeof size !== 'number' || !Number.isSafeInteger(size) || size < 0) {
      return false;
    }
    if (eventId === undefined && receivedAtMs === undefined) {
      return true;
    }
    return typeof receivedAtMs === 'number' && Number.isSafeInteger(receivedAtMs) && receivedAtMs > 0 &&
      typeof eventId === 'string' && eventId.length > 0 && eventId.length <= 96 &&
      eventId.startsWith(`${receivedAtMs}:`) && /^[0-9]+:[0-9]+$/.test(eventId);
  }
}
