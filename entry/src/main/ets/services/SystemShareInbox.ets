import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';

export interface SharedFileDraft {
  id: number;
  uris: string[];
}

const UNSAFE_SHARE_CONTROLS_AND_BIDI: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
const STRIP_SHARE_CONTROLS_AND_BIDI: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

/** A share is a draft, never permission to send to a remembered peer. */
export class SystemShareInbox {
  private static drafts: SharedFileDraft[] = [];
  private static nextId: number = 0;
  private static pending: Promise<void> = Promise.resolve();
  private static parsingCount: number = 0;

  static accepts(want: Want): boolean {
    return want.action === 'ohos.want.action.sendData' ||
      want.action === 'ohos.want.action.sendMultipleData';
  }

  static fileUris(records: systemShare.SharedRecord[]): string[] {
    if (records.length === 0 || records.length > 100) {
      throw new Error('invalid_share_count');
    }
    const uris: string[] = [];
    for (const record of records) {
      const uri: string = record.uri ?? '';
      // Only externally granted file URIs. Never turn a supplied local path or
      // our own private-file URI into a network upload on another app's behalf.
      if (!SystemShareInbox.isValidExternalFileUri(uri)) {
        throw new Error('invalid_share_uri');
      }
      if (!uris.includes(uri)) {
        uris.push(uri);
      }
    }
    return uris;
  }

  static summarizeFileNames(draft: SharedFileDraft | undefined): string {
    if (draft === undefined || !Array.isArray(draft.uris) || draft.uris.length === 0) {
      return '';
    }
    const names: string[] = [];
    const maxPreviewNames: number = 3;
    for (let index: number = 0; index < draft.uris.length && names.length < maxPreviewNames; index++) {
      const baseName: string = SystemShareInbox.extractDisplayBaseName(draft.uris[index]);
      if (baseName.length > 0) {
        names.push(baseName);
      }
    }
    if (names.length === 0) {
      return '';
    }
    const summary: string = names.join(', ');
    const remaining: number = draft.uris.length - names.length;
    return remaining > 0 ? `${summary} (+${remaining})` : summary;
  }

  static receive(want: Want): void {
    if (!SystemShareInbox.accepts(want)) { return; }
    // Count unresolved Wants too: a slow provider must not allow an unbounded
    // chain of closures and URI grants to accumulate.
    if (SystemShareInbox.drafts.length + SystemShareInbox.parsingCount >= 5) {
      AppStorage.setOrCreate('systemShareError', Date.now());
      return;
    }
    SystemShareInbox.parsingCount++;
    // Serialize cold/warm launches so a slow earlier Want cannot replace a
    // newer draft. URI grants remain owned by the receiving UIAbility.
    SystemShareInbox.pending = SystemShareInbox.pending.then(async () => {
      if (SystemShareInbox.drafts.length >= 5) { throw new Error('share_queue_full'); }
      const data: systemShare.SharedData = await systemShare.getSharedData(want);
      const uris: string[] = SystemShareInbox.fileUris(data.getRecords());
      SystemShareInbox.nextId = Math.max(Date.now(), SystemShareInbox.nextId + 1);
      const draft: SharedFileDraft = { id: SystemShareInbox.nextId, uris: uris };
      SystemShareInbox.drafts.push(draft);
      SystemShareInbox.notify();
    }).catch(() => {
      AppStorage.setOrCreate('systemShareError', Date.now());
    }).finally(() => {
      SystemShareInbox.parsingCount--;
    });
  }

  static first(): SharedFileDraft | undefined { return SystemShareInbox.drafts[0]; }

  static remove(id: number): void {
    SystemShareInbox.drafts = SystemShareInbox.drafts.filter((draft: SharedFileDraft) => draft.id !== id);
    SystemShareInbox.notify();
  }

  private static notify(): void {
    AppStorage.setOrCreate('systemShareRevision', (AppStorage.get<number>('systemShareRevision') ?? 0) + 1);
  }

  private static isValidExternalFileUri(uri: string): boolean {
    if (typeof uri !== 'string' || uri.length < 10 || uri.length > 8192 ||
      UNSAFE_SHARE_CONTROLS_AND_BIDI.test(uri) || !uri.startsWith('file://')) {
      return false;
    }
    const rest: string = uri.substring(7);
    if (rest.includes('?') || rest.includes('#') || rest.includes('\\')) {
      return false;
    }
    const slashIndex: number = rest.indexOf('/');
    if (slashIndex <= 0) {
      return false;
    }
    const rawAuthority: string = rest.substring(0, slashIndex);
    const rawPath: string = rest.substring(slashIndex);
    if (rawPath.length <= 1 || rawAuthority.includes('@') || rawAuthority.includes(':') ||
      rawAuthority.includes('\\') || /\s/.test(rawAuthority)) {
      return false;
    }

    let decodedAuthority: string = '';
    let decodedPath: string = '';
    try {
      decodedAuthority = decodeURIComponent(rawAuthority).toLowerCase();
      decodedPath = decodeURIComponent(rawPath);
    } catch (_error) {
      return false;
    }

    if (decodedAuthority.length === 0 || decodedAuthority === '.' || decodedAuthority === '..' ||
      UNSAFE_SHARE_CONTROLS_AND_BIDI.test(decodedAuthority) ||
      decodedAuthority === 'localhost' || decodedAuthority === '127.0.0.1' ||
      decodedAuthority === '[::1]' || decodedAuthority === '::1' ||
      decodedAuthority.includes('io.github.tailscaleohos') ||
      !/^[a-z0-9._-]+$/.test(decodedAuthority)) {
      return false;
    }

    if (!decodedPath.startsWith('/') || decodedPath.length <= 1 ||
      UNSAFE_SHARE_CONTROLS_AND_BIDI.test(decodedPath) || decodedPath.includes('\\')) {
      return false;
    }

    const rawSegments: string[] = rawPath.split('/');
    for (let i: number = 1; i < rawSegments.length; i++) {
      if (rawSegments[i] === '.' || rawSegments[i] === '..') {
        return false;
      }
    }

    const segments: string[] = decodedPath.split('/');
    let nonEmptySegments: number = 0;
    for (let i: number = 1; i < segments.length; i++) {
      const seg: string = segments[i];
      if (seg.length === 0) {
        continue;
      }
      if (seg === '.' || seg === '..' || /^(?:%2e|\.)+$/i.test(seg)) {
        return false;
      }
      nonEmptySegments++;
    }
    if (nonEmptySegments === 0) {
      return false;
    }

    const lowerPath: string = decodedPath.toLowerCase();
    if (lowerPath.includes('/data/storage/el') || lowerPath.includes('/data/app/el') ||
      lowerPath.includes('/data/service/el') || lowerPath.includes('tailscaled.state') ||
      lowerPath.includes('io.github.tailscaleohos')) {
      return false;
    }
    return true;
  }

  private static extractDisplayBaseName(uri: string): string {
    if (typeof uri !== 'string' || uri.length === 0) {
      return '';
    }
    let pathPart: string = uri;
    if (uri.startsWith('file://')) {
      const rest: string = uri.substring(7);
      const slashIndex: number = rest.indexOf('/');
      pathPart = slashIndex >= 0 ? rest.substring(slashIndex) : rest;
    }
    const queryIndex: number = pathPart.indexOf('?');
    if (queryIndex >= 0) {
      pathPart = pathPart.substring(0, queryIndex);
    }
    const hashIndex: number = pathPart.indexOf('#');
    if (hashIndex >= 0) {
      pathPart = pathPart.substring(0, hashIndex);
    }
    let decoded: string = pathPart;
    try {
      decoded = decodeURIComponent(pathPart);
    } catch (_error) {
      decoded = pathPart;
    }
    const trimmedSlashes: string = decoded.replace(/\/+$/, '');
    const lastSlash: number = Math.max(trimmedSlashes.lastIndexOf('/'), trimmedSlashes.lastIndexOf('\\'));
    const rawBase: string = lastSlash >= 0 ? trimmedSlashes.substring(lastSlash + 1) : trimmedSlashes;
    return rawBase.replace(STRIP_SHARE_CONTROLS_AND_BIDI, '').trim();
  }
}
