import { common, CompletionHandlerForAbilityStartCallback, wantConstant } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { DiagnosticReportResult } from './DiagnosticReportService';

class FeedbackMailCallback {
  completionHandler?: CompletionHandlerForAbilityStartCallback;
  private readonly failure: (code: number) => void;

  constructor(failure: (code: number) => void) { this.failure = failure; }

  onError(code: number, _name: string, _message: string): void { this.failure(code); }

  onResult(_result: common.AbilityResult): void {
    // A returned/cancelled composer is not evidence that a message was sent.
  }
}

/** Opens a user-reviewed mail draft with a read-only diagnostic attachment. Never sends mail. */
export class FeedbackEmailGateway {
  async open(context: common.UIAbilityContext, report: DiagnosticReportResult,
    recipient: string, subject: string, body: string, onFailure: (code: number) => void,
    onStage: (stage: string) => void = (_stage: string): void => {}): Promise<void> {
    onStage('validate');
    if (!/^TailscaleOHOS-Diagnostic-[A-Za-z0-9-]+\.zip$/.test(report.fileName) ||
      report.path !== `${context.cacheDir}/${report.fileName}` || report.size <= 0) {
      throw new Error('Invalid diagnostic attachment');
    }
    const stat: fileIo.Stat = fileIo.statSync(report.path);
    if (!stat.isFile() || stat.size !== report.size) throw new Error('Diagnostic attachment unavailable');
    onStage('uri');
    const parameters: Record<string, Object> = {
      'sceneType': 1,
      'email': [encodeURI(recipient)],
      'subject': encodeURI(subject),
      'body': encodeURI(body),
      'ability.params.stream': [encodeURI(fileUri.getUriFromPath(report.path))],
      'ability.want.params.uriPermissionFlag': wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    let failed: boolean = false;
    const failure = (code: number): void => {
      if (failed) return;
      failed = true;
      onFailure(code);
    };
    onStage('callback');
    const callback: FeedbackMailCallback = new FeedbackMailCallback(failure);
    // The SDK declaration is a callback shape; it is not a runtime constructor
    // on every supported device. Supply its documented functions directly.
    const completion: CompletionHandlerForAbilityStartCallback = {
      onRequestFailure: (_name: string, code: number, _message: string): void => {
        // AbilityStartFailureCode.FAILURE_CODE_USER_CANCEL = 1.
        if (code !== 1) failure(code);
      },
      onRequestSuccess: (_name: string): void => {}
    };
    callback.completionHandler = completion;
    onStage('resolve');
    await context.startAbilityByType('mail', parameters, callback as common.AbilityStartCallback);
    if (failed) throw new Error('Mail attachment handoff failed');
  }
}
