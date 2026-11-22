/** Validates input without retaining credentials or returning them in errors. */
export class AuthKeyLogin {
  static validationError(value: string, customControl: boolean): string {
    const key: string = value.trim();
    if (key.length === 0) {
      return 'empty';
    }
    if (key.startsWith('tskey-api-') || key.startsWith('tskey-client-')) {
      return 'management_key';
    }
    if (key.length > 4096 || !/^[A-Za-z0-9_-]+$/.test(key) || key === 'tskey-auth-' ||
      (key.startsWith('tskey-') && !key.startsWith('tskey-auth-')) ||
      (!customControl && !key.startsWith('tskey-auth-'))) {
      return 'invalid';
    }
    return '';
  }
}
