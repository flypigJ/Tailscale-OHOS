import nativeBridge from 'libtailscale_ohos.so';
import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

export enum VpnCommandState {
  STOPPED = 'stopped',
  STARTING = 'starting',
  NEEDS_LOGIN = 'needs_login',
  RUNNING = 'running',
  STOPPING = 'stopping',
  TIMED_OUT = 'timed_out'
}

export enum VpnCoreCommand {
  CONNECT = 'connect',
  LOGIN = 'login',
  DISCONNECT = 'disconnect'
}

/**
 * Single owner for core VPN command generations. UI lifecycle invalidation
 * rejects late Promise completions without changing the VPN's own lifecycle.
 */
export class VpnCommandStateMachine {
  private lifecycleGeneration: number = 0;
  private activeCommandId: number = 0;
  private nextCommandId: number = 1;
  private state: VpnCommandState = VpnCommandState.STOPPED;

  begin(command: VpnCoreCommand): number {
    if (this.activeCommandId > 0) {
      return 0;
    }
    this.activeCommandId = this.nextCommandId++;
    if (command === VpnCoreCommand.CONNECT) {
      this.state = VpnCommandState.STARTING;
    } else if (command === VpnCoreCommand.LOGIN) {
      this.state = VpnCommandState.NEEDS_LOGIN;
    } else {
      this.state = VpnCommandState.STOPPING;
    }
    return this.activeCommandId;
  }

  isActive(commandId: number): boolean {
    return commandId > 0 && commandId === this.activeCommandId;
  }

  complete(commandId: number, state: VpnCommandState): boolean {
    if (!this.isActive(commandId)) {
      return false;
    }
    this.activeCommandId = 0;
    this.state = state;
    return true;
  }

  timeout(commandId: number): boolean {
    return this.complete(commandId, VpnCommandState.TIMED_OUT);
  }

  invalidateLifecycle(): void {
    this.lifecycleGeneration++;
    this.activeCommandId = 0;
  }

  currentState(): VpnCommandState {
    return this.state;
  }

  currentLifecycleGeneration(): number {
    return this.lifecycleGeneration;
  }
}

/** Owns M4A Native, VPN Extension, and command-file IPC operations. */
export class VpnCommandGateway {
  private writeTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
          // A failed write may already have closed the descriptor.
        }
      }
    }
  }

  startBackend(stateDir: string, deviceModel: string, osVersion: string, controlUrl: string): string {
    return nativeBridge.backendStart(stateDir, deviceModel, osVersion, controlUrl);
  }

  async stopBackend(): Promise<string> {
    return await nativeBridge.backendStopAsync();
  }

  backendStatus(): string {
    return nativeBridge.backendStatus();
  }

  async requestVpnConfig(): Promise<string> {
    return await nativeBridge.backendVpnConfigAsync();
  }

  async requestLoginUrl(): Promise<string> {
    return await nativeBridge.backendAuthURLAsync();
  }

  async startVpnExtension(want: Want): Promise<void> {
    await vpnExtension.startVpnExtensionAbility(want);
  }

  async stopVpnExtension(want: Want): Promise<void> {
    await vpnExtension.stopVpnExtensionAbility(want);
  }

  stageConnectConfig(filesDir: string, fileName: string, config: string): boolean {
    const path: string = `${filesDir}/${fileName}`;
    const temporaryPath: string = `${path}.tmp`;
    const handoff: VpnConnectConfigHandoff = { createdAtMs: Date.now(), config: config };
    try {
      if (!this.writeTextFile(temporaryPath, JSON.stringify(handoff))) {
        return false;
      }
      fileIo.renameSync(temporaryPath, path);
      return true;
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
        // The next command replaces a leftover temporary handoff.
      }
      return false;
    }
  }

  readConnectConfig(filesDir: string, fileName: string): VpnConnectConfigHandoff | undefined {
    try {
      const path: string = `${filesDir}/${fileName}`;
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      return JSON.parse(fileIo.readTextSync(path)) as VpnConnectConfigHandoff;
    } catch (_error) {
      return undefined;
    }
  }

  writeCommandFile(filesDir: string, fileName: string, content: string): boolean {
    return this.writeTextFile(`${filesDir}/${fileName}`, content);
  }

  readCommandFile(filesDir: string, fileName: string): string | undefined {
    try {
      const path: string = `${filesDir}/${fileName}`;
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      return fileIo.readTextSync(path);
    } catch (_error) {
      return undefined;
    }
  }
}

export interface VpnConnectConfigHandoff {
  createdAtMs: number;
  config: string;
}
