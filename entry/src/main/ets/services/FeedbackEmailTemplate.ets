import { DiagnosticFeedbackContext } from './DiagnosticReportService';

export class FeedbackEmailTemplate {
  static render(template: string, context: DiagnosticFeedbackContext | undefined,
    yes: string, no: string, unknown: string): string {
    const text = (value: string | undefined): string => {
      if (value === undefined || value.trim().length === 0 || value === 'unknown') return unknown;
      return value.replace(/[\r\n\t]/g, ' ').substring(0, 200);
    };
    const formatNumber = (value: number | undefined): string =>
      value !== undefined && Number.isFinite(value) && value > 0 ? `${Math.floor(value)}` : unknown;
    const flag = (value: boolean | undefined): string => value === undefined ? unknown : value ? yes : no;
    const fields: Record<string, string> = {
      'appVersion': text(context?.appVersion),
      'appVersionCode': formatNumber(context?.appVersionCode),
      'tailscaleVersion': text(context?.tailscaleVersion),
      'model': text(context?.model),
      'system': text(context?.system),
      'sdkApiVersion': formatNumber(context?.sdkApiVersion),
      'generatedAt': text(context?.generatedAt),
      'signedIn': flag(context?.signedIn),
      'exitNodeSelected': flag(context?.exitNodeSelected),
      'acceptSubnetRoutes': flag(context?.acceptSubnetRoutes)
    };
    // One pass: inserted data cannot be interpreted as another template field.
    return template.replace(/\{([a-zA-Z]+)\}/g, (_match: string, key: string): string => fields[key] ?? unknown);
  }
}
