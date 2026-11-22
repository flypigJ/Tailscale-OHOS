import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TAILDROP_TEXT_MAX_CLIPBOARD_BYTES,
  TaildropIncomingFileSummary,
  classifyFileContentKind,
  isMediaFileName
} from '@tailscale/common';
import {
  buildSignedTaildropEventId,
  hasUnsafeControlOrBidiChars,
  stripUnsafeControlAndBidiChars
} from './AppShellIntentAdapter';

const DOMAIN: number = 0x0000;
const TAG: string = 'TaildropNotifications';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const PROGRESS_NOTIFICATION_ID: number = 420001;
const COMPLETION_NOTIFICATION_BASE_ID: number = 421000;
const COMPLETION_NOTIFICATION_ID_RANGE: number = 500000000;
const COMPLETION_ACTIONS_PER_NOTIFICATION: number = 4;

export type TaildropNotificationFile = TaildropIncomingFileSummary;

let notificationEnabled: boolean = false;
let nextCompletionNotificationId: number =
  COMPLETION_NOTIFICATION_BASE_ID + Math.floor(Math.random() * COMPLETION_NOTIFICATION_ID_RANGE);

export async function publishTaildropProgress(context: common.Context, file: TaildropNotificationFile): Promise<void> {
  if (!await canPublish()) {
    return;
  }
  const safeDisplayName: string = sanitizeNotificationDisplayLabel(file.name);
  const progress: number | undefined = progressPercent(file);
  const request: notificationManager.NotificationRequest = {
    id: PROGRESS_NOTIFICATION_ID,
    notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
    isOngoing: true,
    isAlertOnce: true,
    content: {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: {
        title: stringResource(context, 'notification_taildrop_receiving_title', 'Receiving file'),
        text: safeDisplayName,
        additionalText: progress === undefined ?
          stringResource(context, 'notification_taildrop_receiving_indeterminate', 'Receiving') : `${progress}%`
      }
    }
  };
  try {
    if (progress !== undefined && await notificationManager.isSupportTemplate('downloadTemplate')) {
      request.template = {
        name: 'downloadTemplate',
        data: {
          title: stringResource(context, 'notification_taildrop_receiving_title', 'Receiving file'),
          fileName: safeDisplayName,
          progressValue: progress
        }
      };
    }
    await notificationManager.publish(request);
  } catch (error) {
    logPublishError('progress', error as BusinessError);
  }
}

export async function clearTaildropProgress(): Promise<void> {
  try {
    await notificationManager.cancel(PROGRESS_NOTIFICATION_ID);
  } catch (_error) {
    // The notification may already have been dismissed by the system.
  }
}

export async function publishTaildropSavePrompt(context: common.Context, fileName: string, size: number,
  receivedAtMs: number): Promise<void> {
  if (!await canPublish()) {
    return;
  }
  try {
    const notificationId: number = allocateCompletionNotificationId();
    const normalizedReceivedAtMs: number = Number.isSafeInteger(receivedAtMs) && receivedAtMs > 0 ?
      receivedAtMs : Date.now();
    const filesDir: string = context !== undefined && typeof context.filesDir === 'string' ?
      context.filesDir.trim() : '';
    const safeDisplayName: string = sanitizeNotificationDisplayLabel(fileName);
    const openEventId: string = buildSignedTaildropEventId(
      filesDir, 'open', fileName, size, normalizedReceivedAtMs, notificationId);
    const laterEventId: string = buildSignedTaildropEventId(
      filesDir, 'later', fileName, size, normalizedReceivedAtMs, notificationId);
    const requiresOpenFallback: boolean = isMediaFileName(fileName) || hasUnsafeControlOrBidiChars(fileName);
    const candidateSaveEventId: string = requiresOpenFallback ? '' : buildSignedTaildropEventId(
      filesDir, 'save', fileName, size, normalizedReceivedAtMs, notificationId);
    const saveActionName: string = candidateSaveEventId.length > 0 ? 'save' : 'open';
    const saveEventId: string = candidateSaveEventId.length > 0 ? candidateSaveEventId : openEventId;
    const actionRequestCode: number = notificationId * COMPLETION_ACTIONS_PER_NOTIFICATION;
    const openAgent: WantAgent = await taildropActionAgent(
      actionRequestCode, 'open', fileName, size, normalizedReceivedAtMs, openEventId);
    const saveAgent: WantAgent = await taildropActionAgent(
      actionRequestCode + 1, saveActionName, fileName, size,
      normalizedReceivedAtMs, saveEventId);
    const laterAgent: WantAgent = await taildropActionAgent(
      actionRequestCode + 2, 'later', fileName, size, normalizedReceivedAtMs, laterEventId);
    const saveAction: notificationManager.NotificationActionButton = {
      title: saveActionName === 'open' ?
        stringResource(context, 'notification_taildrop_open_action', 'Open') :
        taildropSaveActionTitle(context, fileName, size),
      wantAgent: saveAgent
    };
    const laterAction: notificationManager.NotificationActionButton = {
      title: stringResource(context, 'notification_taildrop_later_action', 'Later'),
      wantAgent: laterAgent
    };
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      isAlertOnce: false,
      isFloatingIcon: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: stringResource(context, 'notification_taildrop_received_title', 'File received'),
          text: safeDisplayName,
          additionalText: stringResource(context, 'notification_taildrop_received_message',
            'Choose how to save the file')
        }
      },
      wantAgent: openAgent,
      actionButtons: [laterAction, saveAction]
    };
    await notificationManager.publish(request);
  } catch (error) {
    logPublishError('completion', error as BusinessError);
  }
}

async function taildropActionAgent(requestCode: number, action: string, fileName: string,
  size: number, receivedAtMs: number, eventId: string): Promise<WantAgent> {
  return await wantAgent.getWantAgent({
    wants: [{
      bundleName: BUNDLE_NAME,
      abilityName: ENTRY_ABILITY_NAME,
      parameters: {
        taildropOpenInbox: true,
        taildropNotificationAction: action,
        taildropNotificationFileName: fileName,
        taildropNotificationFileSize: size,
        taildropNotificationReceivedAtMs: receivedAtMs,
        taildropNotificationEventId: eventId
      }
    }],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: requestCode,
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  });
}

function taildropSaveActionTitle(context: common.Context, fileName: string, size: number): string {
  if (isMediaFileName(fileName)) {
    return stringResource(context, 'notification_taildrop_open_action', 'Open');
  }
  return classifyFileContentKind(fileName, size, TAILDROP_TEXT_MAX_CLIPBOARD_BYTES) === 'text' ?
    stringResource(context, 'notification_taildrop_copy_action', 'Copy') :
    stringResource(context, 'notification_taildrop_save_action', 'Save');
}

async function canPublish(): Promise<boolean> {
  if (notificationEnabled) {
    return true;
  }
  try {
    notificationEnabled = await notificationManager.isNotificationEnabled();
  } catch (error) {
    logPublishError('authorization', error as BusinessError);
    return false;
  }
  return notificationEnabled;
}

function progressPercent(file: TaildropNotificationFile): number | undefined {
  if (file.declaredSize <= 0) {
    return undefined;
  }
  return Math.max(0, Math.min(100, Math.round(file.received * 100 / file.declaredSize)));
}

function allocateCompletionNotificationId(): number {
  const notificationId: number = nextCompletionNotificationId;
  nextCompletionNotificationId += 1;
  if (nextCompletionNotificationId >= COMPLETION_NOTIFICATION_BASE_ID + COMPLETION_NOTIFICATION_ID_RANGE) {
    nextCompletionNotificationId = COMPLETION_NOTIFICATION_BASE_ID;
  }
  return notificationId;
}

function stringResource(context: common.Context, name: string, fallback: string): string {
  try {
    return context.resourceManager.getStringByNameSync(name);
  } catch (_error) {
    return fallback;
  }
}

function sanitizeNotificationDisplayLabel(value: string): string {
  const cleaned: string = stripUnsafeControlAndBidiChars(value).trim();
  return cleaned.length > 0 ? cleaned : 'file';
}

function logPublishError(operation: string, error: BusinessError): void {
  hilog.warn(DOMAIN, TAG, 'Taildrop notification %{public}s failed. code=%{public}d',
    operation, error.code ?? -1);
}
