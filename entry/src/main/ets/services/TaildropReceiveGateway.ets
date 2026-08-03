export interface TaildropNotificationActionRequest {
  action: string;
  fileName: string;
  size: number;
  receivedAtMs: number;
  eventId: string;
  atMs: number;
}

export interface TaildropReceiveRequest {
  requestId: number;
  action: string;
  name: string;
  inboxRoot: string;
  path: string;
}

export interface TaildropReceiveResult {
  requestId: number;
  action: string;
  state: string;
  reason: string;
  name: string;
  size: number;
  path: string;
}

/** M6A owner for receive protocol payloads and notification/delete idempotency. */
export class TaildropReceiveGateway {
  private claimedNotificationActions: string[] = [];
  private claimedRemoteDeletes: string[] = [];

  parseNotificationAction(value: string): TaildropNotificationActionRequest | undefined {
    try {
      const request: TaildropNotificationActionRequest = JSON.parse(value) as TaildropNotificationActionRequest;
      if ((request.action !== 'open' && request.action !== 'save' && request.action !== 'later') ||
        typeof request.fileName !== 'string' || request.fileName.length === 0 || request.fileName.length > 255 ||
        request.fileName.includes('/') || request.fileName.includes('\\') ||
        !Number.isSafeInteger(request.size) || request.size < 0 ||
        !Number.isSafeInteger(request.receivedAtMs) || request.receivedAtMs < -1 ||
        typeof request.eventId !== 'string' || request.eventId.length === 0 || request.eventId.length > 96) {
        return undefined;
      }
      return request;
    } catch (_error) {
      return undefined;
    }
  }

  claimNotificationAction(request: TaildropNotificationActionRequest): boolean {
    const key: string = `${request.eventId}:${request.action}`;
    if (this.claimedNotificationActions.includes(key)) {
      return false;
    }
    this.claimedNotificationActions.push(key);
    return true;
  }

  releaseNotificationAction(request: TaildropNotificationActionRequest | undefined): void {
    if (request === undefined) {
      return;
    }
    const key: string = `${request.eventId}:${request.action}`;
    this.claimedNotificationActions = this.claimedNotificationActions.filter(
      (candidate: string) => candidate !== key);
  }

  createStageRequest(requestId: number, name: string, inboxRoot: string): TaildropReceiveRequest {
    return {
      requestId: requestId,
      action: 'stage',
      name: name,
      inboxRoot: inboxRoot,
      path: `${inboxRoot}/${requestId}.taildrop`
    };
  }

  createDeleteRequest(requestId: number, name: string): TaildropReceiveRequest {
    return { requestId: requestId, action: 'delete', name: name, inboxRoot: '', path: '' };
  }

  claimRemoteDelete(requestId: number, name: string): boolean {
    const key: string = `${requestId}:${name}`;
    if (this.claimedRemoteDeletes.includes(key)) {
      return false;
    }
    this.claimedRemoteDeletes.push(key);
    if (this.claimedRemoteDeletes.length > 64) {
      this.claimedRemoteDeletes.shift();
    }
    return true;
  }

  matchesResponse(expected: TaildropReceiveResult, result: TaildropReceiveResult): boolean {
    return result.requestId === expected.requestId && result.action === expected.action;
  }
}
