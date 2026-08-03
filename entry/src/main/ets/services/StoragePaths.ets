import { common } from '@kit.AbilityKit';

const VPN_STATUS_FILE_NAME: string = 'vpn-probe-status.txt';

/**
 * Read-only path adapter for existing private application storage.
 *
 * This adapter deliberately does not select an encryption area, create a
 * directory, or move data. `context.filesDir` remains the platform-resolved
 * path and therefore preserves the existing order and failure semantics.
 */
export class StoragePaths {
  static filesDir(context: common.Context): string {
    return context.filesDir;
  }

  static vpnStatusPath(filesDir: string): string {
    return `${filesDir}/${VPN_STATUS_FILE_NAME}`;
  }
}
