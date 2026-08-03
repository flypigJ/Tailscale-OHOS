import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'TaildropNotifications';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const PROGRESS_NOTIFICATION_ID: number = 420001;
const COMPLETION_NOTIFICATION_BASE_ID: number = 421000;
const COMPLETION_NOTIFICATION_ID_RANGE: number = 500000000;
const COMPLETION_ACTIONS_PER_NOTIFICATION: number = 4;
const TEXT_CLIPBOARD_MAX_BYTES: number = 1024 * 1024;
const IMAGE_EXTENSIONS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'dng'];
const VIDEO_EXTENSIONS: string[] = ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', '3gp', 'ts'];
const TEXT_EXTENSIONS: string[] = [
  'txt', 'md', 'markdown', 'json', 'xml', 'csv', 'log', 'yaml', 'yml', 'ini', 'conf', 'js', 'ts', 'ets',
  'html', 'css', 'sh', 'py', 'go', 'java', 'c', 'cpp', 'h', 'hpp', 'rs', 'kt', 'swift'
];

export interface TaildropNotificationFile {
  name: string;
  declaredSize: number;
  received: number;
  startedAtMs: number;
}

let notificationEnabled: boolean = false;
let nextCompletionNotificationId: number =
  COMPLETION_NOTIFICATION_BASE_ID + Math.floor(Math.random() * COMPLETION_NOTIFICATION_ID_RANGE);

export async function publishTaildropProgress(context: common.Context, file: TaildropNotificationFile): Promise<void> {
  if (!await canPublish()) {
    return;
  }
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
        text: file.name,
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
          fileName: file.name,
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
    const eventId: string = `${normalizedReceivedAtMs}:${notificationId}`;
    const actionRequestCode: number = notificationId * COMPLETION_ACTIONS_PER_NOTIFICATION;
    const openAgent: WantAgent = await taildropActionAgent(
      actionRequestCode, 'open', fileName, size, normalizedReceivedAtMs, eventId);
    const requiresSecureMediaSave: boolean = isMediaFile(fileName);
    const saveAgent: WantAgent = await taildropActionAgent(
      actionRequestCode + 1, requiresSecureMediaSave ? 'open' : 'save', fileName, size,
      normalizedReceivedAtMs, eventId);
    const laterAgent: WantAgent = await taildropActionAgent(
      actionRequestCode + 2, 'later', fileName, size, normalizedReceivedAtMs, eventId);
    const saveAction: notificationManager.NotificationActionButton = {
      title: taildropSaveActionTitle(context, fileName, size),
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
          text: fileName,
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
  if (isMediaFile(fileName)) {
    return stringResource(context, 'notification_taildrop_open_action', 'Open');
  }
  return isTextFile(fileName, size) ?
    stringResource(context, 'notification_taildrop_copy_action', 'Copy') :
    stringResource(context, 'notification_taildrop_save_action', 'Save');
}

function isMediaFile(fileName: string): boolean {
  const extensionIndex: number = fileName.lastIndexOf('.');
  if (extensionIndex < 1) {
    return false;
  }
  const extension: string = fileName.substring(extensionIndex + 1).toLowerCase();
  return IMAGE_EXTENSIONS.includes(extension) || VIDEO_EXTENSIONS.includes(extension);
}

function isTextFile(fileName: string, size: number): boolean {
  const extensionIndex: number = fileName.lastIndexOf('.');
  if (extensionIndex < 1 || size < 0 || size > TEXT_CLIPBOARD_MAX_BYTES) {
    return false;
  }
  return TEXT_EXTENSIONS.includes(fileName.substring(extensionIndex + 1).toLowerCase());
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

function logPublishError(operation: string, error: BusinessError): void {
  hilog.warn(DOMAIN, TAG, 'Taildrop notification %{public}s failed. code=%{public}d',
    operation, error.code ?? -1);
}
