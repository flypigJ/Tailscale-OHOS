/**
 * M9A's single boundary for data that can leave a Native error path or be
 * persisted in a diagnostic artifact.  It deliberately keeps only a stable
 * error category and numeric code; native error text is never retained.
 */
export interface SanitizedDiagnosticError {
  category: string;
  code: number;
  retryable: boolean;
}

export class DiagnosticPrivacy {
  static readonly MAX_EVENTS_PER_FILE: number = 100;
  static readonly MAX_EVENT_FILE_BYTES: number = 24 * 1024;
  static readonly MAX_REPORT_JSON_BYTES: number = 128 * 1024;
  static readonly MAX_REPORT_SUMMARY_BYTES: number = 24 * 1024;

  static classifyError(error: Object): SanitizedDiagnosticError {
    const raw: string = DiagnosticPrivacy.redactForLog(DiagnosticPrivacy.errorText(error)).toLowerCase();
    const code: number = DiagnosticPrivacy.errorCode(raw);
    if (raw.includes('timeout') || raw.includes('timed out')) {
      return { category: 'timeout', code: code, retryable: true };
    }
    if (raw.includes('permission') || raw.includes('denied') || raw.includes('unauthorized')) {
      return { category: 'permission', code: code, retryable: false };
    }
    if (raw.includes('unavailable') || raw.includes('not found') || raw.includes('not ready')) {
      return { category: 'unavailable', code: code, retryable: true };
    }
    if (raw.includes('invalid') || raw.includes('malformed')) {
      return { category: 'invalid_request', code: code, retryable: false };
    }
    return { category: 'native_error', code: code, retryable: true };
  }

  static formatNativeFailure(prefix: string, error: Object): string {
    const classified: SanitizedDiagnosticError = DiagnosticPrivacy.classifyError(error);
    const codeSuffix: string = classified.code === 0 ? '' : ` | code=${classified.code}`;
    return `${prefix}: ${classified.category}${codeSuffix}`;
  }

  static formatLogError(error: Object): string {
    const classified: SanitizedDiagnosticError = DiagnosticPrivacy.classifyError(error);
    return `category=${classified.category} code=${classified.code} retryable=${classified.retryable}`;
  }

  static redactForLog(value: string): string {
    return value
      .replace(/(https?:\/\/)[^\s"'<>]+/gi, '$1<redacted>')
      .replace(/\b(?:bearer|basic)\s+[^\s,;]+/gi, '<redacted-auth>')
      .replace(/\b(?:access[_-]?token|auth(?:orization)?|password|passwd|secret|private[_-]?key|cookie|set-cookie|x-[\w-]*token)\s*[:=]\s*[^\s,;]+/gi,
        '<redacted-secret>')
      .replace(/([?&](?:access[_-]?token|auth(?:orization)?|token|signature|sig|key|password|secret|code)=)[^&#\s]+/gi,
        '$1<redacted>');
  }

  static exceedsByteLimit(value: string, maximum: number): boolean {
    return DiagnosticPrivacy.utf8ByteLength(value) > maximum;
  }

  static utf8ByteLength(value: string): number {
    let size: number = 0;
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index);
      if (code <= 0x7f) {
        size++;
      } else if (code <= 0x7ff) {
        size += 2;
      } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length &&
        value.charCodeAt(index + 1) >= 0xdc00 && value.charCodeAt(index + 1) <= 0xdfff) {
        size += 4;
        index++;
      } else {
        size += 3;
      }
    }
    return size;
  }

  private static errorText(error: Object): string {
    try {
      const serialized: string | undefined = JSON.stringify(error);
      if (serialized !== undefined && serialized.length > 0 && serialized !== '{}') {
        return serialized;
      }
    } catch (_error) {
      // Fall through to the platform's string form; it is redacted before use.
    }
    return `${error}`;
  }

  private static errorCode(value: string): number {
    const match: RegExpMatchArray | null = value.match(/(?:code|errno)\s*[=:]\s*(-?\d+)/i);
    return match === null ? 0 : Number(match[1]);
  }
}
