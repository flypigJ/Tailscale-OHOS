import { Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';

export interface AppShellFeatureAction {
  openTaildropInbox: boolean;
  taildropNotificationAction: string;
}

interface SerializedNotificationActionPayload {
  action: string;
  fileName: string;
  size: number;
  receivedAtMs: number;
  eventId: string;
  atMs: number;
}

export const TAILDROP_NOTIFICATION_SECRET_FILE_NAME: string = 'taildrop-notification-secret-v1.txt';
const SECRET_BYTE_LENGTH: number = 32;
const SECRET_HEX_LENGTH: number = 64;
const MAX_SECRET_FILE_BYTES: number = 256;
const MAX_EVENT_ID_LENGTH: number = 128;
const HMAC_DOMAIN_PREFIX: string = 'taildrop-want-v1';

const SHA256_INIT: number[] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
];

const SHA256_K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

const UNSAFE_CONTROL_AND_BIDI_PATTERN: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
const UNSAFE_CONTROL_AND_BIDI_GLOBAL: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

export function hasUnsafeControlOrBidiChars(value: string): boolean {
  return UNSAFE_CONTROL_AND_BIDI_PATTERN.test(value);
}

export function stripUnsafeControlAndBidiChars(value: string): string {
  return value.replace(UNSAFE_CONTROL_AND_BIDI_GLOBAL, '');
}

export function createLocalTextPasteData(text: string): pasteboard.PasteData {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  if (typeof data.getProperty === 'function' && typeof data.setProperty === 'function') {
    const prop: pasteboard.PasteDataProperty = data.getProperty();
    if (prop !== undefined && prop !== null) {
      prop.shareOption = pasteboard.ShareOption.LOCALDEVICE;
      prop.localOnly = true;
      data.setProperty(prop);
    }
  }
  return data;
}

function rotr32(value: number, shift: number): number {
  return (value >>> shift) | (value << (32 - shift));
}

function sha256Bytes(message: Uint8Array): Uint8Array {
  const bitLen: number = message.length * 8;
  const highBits: number = Math.floor(bitLen / 0x100000000);
  const lowBits: number = bitLen >>> 0;
  const rem: number = (message.length + 9) % 64;
  const padZeros: number = rem === 0 ? 0 : (64 - rem);
  const totalLen: number = message.length + 9 + padZeros;
  const padded: Uint8Array = new Uint8Array(totalLen);
  padded.set(message, 0);
  padded[message.length] = 0x80;
  padded[totalLen - 8] = (highBits >>> 24) & 0xff;
  padded[totalLen - 7] = (highBits >>> 16) & 0xff;
  padded[totalLen - 6] = (highBits >>> 8) & 0xff;
  padded[totalLen - 5] = highBits & 0xff;
  padded[totalLen - 4] = (lowBits >>> 24) & 0xff;
  padded[totalLen - 3] = (lowBits >>> 16) & 0xff;
  padded[totalLen - 2] = (lowBits >>> 8) & 0xff;
  padded[totalLen - 1] = lowBits & 0xff;

  let h0: number = SHA256_INIT[0];
  let h1: number = SHA256_INIT[1];
  let h2: number = SHA256_INIT[2];
  let h3: number = SHA256_INIT[3];
  let h4: number = SHA256_INIT[4];
  let h5: number = SHA256_INIT[5];
  let h6: number = SHA256_INIT[6];
  let h7: number = SHA256_INIT[7];
  const w: Int32Array = new Int32Array(64);

  for (let offset: number = 0; offset < totalLen; offset += 64) {
    for (let i: number = 0; i < 16; i++) {
      const base: number = offset + (i * 4);
      w[i] = ((padded[base] << 24) | (padded[base + 1] << 16) |
        (padded[base + 2] << 8) | padded[base + 3]) | 0;
    }
    for (let i: number = 16; i < 64; i++) {
      const w15: number = w[i - 15];
      const w2: number = w[i - 2];
      const s0: number = rotr32(w15, 7) ^ rotr32(w15, 18) ^ (w15 >>> 3);
      const s1: number = rotr32(w2, 17) ^ rotr32(w2, 19) ^ (w2 >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }

    let a: number = h0;
    let b: number = h1;
    let c: number = h2;
    let d: number = h3;
    let e: number = h4;
    let f: number = h5;
    let g: number = h6;
    let h: number = h7;

    for (let i: number = 0; i < 64; i++) {
      const bigS1: number = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
      const ch: number = (e & f) ^ ((~e) & g);
      const temp1: number = (h + bigS1 + ch + SHA256_K[i] + w[i]) | 0;
      const bigS0: number = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
      const maj: number = (a & b) ^ (a & c) ^ (b & c);
      const temp2: number = (bigS0 + maj) | 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) | 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) | 0;
    }

    h0 = (h0 + a) | 0;
    h1 = (h1 + b) | 0;
    h2 = (h2 + c) | 0;
    h3 = (h3 + d) | 0;
    h4 = (h4 + e) | 0;
    h5 = (h5 + f) | 0;
    h6 = (h6 + g) | 0;
    h7 = (h7 + h) | 0;
  }

  const digest: Uint8Array = new Uint8Array(32);
  const words: number[] = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (let i: number = 0; i < 8; i++) {
    const word: number = words[i];
    const base: number = i * 4;
    digest[base] = (word >>> 24) & 0xff;
    digest[base + 1] = (word >>> 16) & 0xff;
    digest[base + 2] = (word >>> 8) & 0xff;
    digest[base + 3] = word & 0xff;
  }
  return digest;
}

function bytesToLowerHex(bytes: Uint8Array): string {
  const hexDigits: string = '0123456789abcdef';
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    const b: number = bytes[i] & 0xff;
    out += hexDigits.charAt(b >>> 4) + hexDigits.charAt(b & 0x0f);
  }
  return out;
}

function hexNibble(code: number): number {
  if (code >= 48 && code <= 57) {
    return code - 48;
  }
  if (code >= 97 && code <= 102) {
    return code - 87;
  }
  return -1;
}

function lowerHexToBytes(hex: string): Uint8Array | undefined {
  if (hex.length % 2 !== 0) {
    return undefined;
  }
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i: number = 0; i < out.length; i++) {
    const hi: number = hexNibble(hex.charCodeAt(i * 2));
    const lo: number = hexNibble(hex.charCodeAt(i * 2 + 1));
    if (hi < 0 || lo < 0) {
      return undefined;
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

function hmacSha256Hex(keyBytes: Uint8Array, messageBytes: Uint8Array): string {
  const normalizedKey: Uint8Array = keyBytes.length > 64 ? sha256Bytes(keyBytes) : keyBytes;
  const iKeyPad: Uint8Array = new Uint8Array(64);
  const oKeyPad: Uint8Array = new Uint8Array(64);
  for (let i: number = 0; i < 64; i++) {
    const kb: number = i < normalizedKey.length ? normalizedKey[i] : 0;
    iKeyPad[i] = kb ^ 0x36;
    oKeyPad[i] = kb ^ 0x5c;
  }
  const innerInput: Uint8Array = new Uint8Array(64 + messageBytes.length);
  innerInput.set(iKeyPad, 0);
  innerInput.set(messageBytes, 64);
  const innerDigest: Uint8Array = sha256Bytes(innerInput);

  const outerInput: Uint8Array = new Uint8Array(64 + innerDigest.length);
  outerInput.set(oKeyPad, 0);
  outerInput.set(innerDigest, 64);
  return bytesToLowerHex(sha256Bytes(outerInput));
}

function constantTimeHexEquals(left: string, right: string): boolean {
  if (left.length !== SECRET_HEX_LENGTH || right.length !== SECRET_HEX_LENGTH) {
    return false;
  }
  let diff: number = 0;
  for (let i: number = 0; i < SECRET_HEX_LENGTH; i++) {
    diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return diff === 0;
}

function secretPathOf(filesDir: string): string {
  const cleanDir: string = typeof filesDir === 'string' ? filesDir.trim().replace(/\/+$/, '') : '';
  return cleanDir.length > 0 ? `${cleanDir}/${TAILDROP_NOTIFICATION_SECRET_FILE_NAME}` : '';
}

export function readExistingTaildropNotificationSecret(filesDir: string): string {
  const secretPath: string = secretPathOf(filesDir);
  if (secretPath.length === 0) {
    return '';
  }
  try {
    if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(secretPath)) {
      return '';
    }
    const raw: string | undefined = AtomicFileStore.readTextBoundedOrThrow(secretPath, MAX_SECRET_FILE_BYTES);
    if (raw === undefined) {
      return '';
    }
    const trimmed: string = raw.trim();
    return /^[0-9a-f]{64}$/.test(trimmed) ? trimmed : '';
  } catch (_error) {
    return '';
  }
}

export function getOrCreateTaildropNotificationSecret(filesDir: string): string {
  const existing: string = readExistingTaildropNotificationSecret(filesDir);
  if (existing.length === SECRET_HEX_LENGTH) {
    return existing;
  }
  const secretPath: string = secretPathOf(filesDir);
  if (secretPath.length === 0) {
    return '';
  }
  try {
    const randomBytes: Uint8Array = cryptoFramework.createRandom()
      .generateRandomSync(SECRET_BYTE_LENGTH).data;
    const generatedHex: string = bytesToLowerHex(randomBytes);
    if (!/^[0-9a-f]{64}$/.test(generatedHex)) {
      return '';
    }
    const writeOptions: AtomicWriteOptions = {
      owner: 'notif-hmac',
      fsync: true,
      maxBytes: MAX_SECRET_FILE_BYTES
    };
    AtomicFileStore.writeAtomicOrThrow(secretPath, generatedHex, writeOptions);
    return generatedHex;
  } catch (_error) {
    return readExistingTaildropNotificationSecret(filesDir);
  }
}

export function computeTaildropNotificationHmac(secretHex: string, action: string, fileName: string,
  size: number, receivedAtMs: number, notificationId: string): string {
  const keyBytes: Uint8Array | undefined = lowerHexToBytes(secretHex);
  if (keyBytes === undefined || keyBytes.length !== SECRET_BYTE_LENGTH) {
    return '';
  }
  const canonicalMessage: string =
    `${HMAC_DOMAIN_PREFIX}\n${action}\n${fileName}\n${size}\n${receivedAtMs}\n${notificationId}`;
  return hmacSha256Hex(keyBytes, AtomicFileStore.encodeUtf8(canonicalMessage));
}

export function buildSignedTaildropEventId(filesDir: string, action: string, fileName: string,
  size: number, receivedAtMs: number, notificationId: number): string {
  const secretHex: string = getOrCreateTaildropNotificationSecret(filesDir);
  const notifIdText: string = String(notificationId);
  if (secretHex.length !== SECRET_HEX_LENGTH) {
    return action === 'save' ? '' : `${receivedAtMs}:${notifIdText}`;
  }
  const mac: string = computeTaildropNotificationHmac(
    secretHex, action, fileName, size, receivedAtMs, notifIdText);
  if (mac.length !== SECRET_HEX_LENGTH) {
    return action === 'save' ? '' : `${receivedAtMs}:${notifIdText}`;
  }
  return `${receivedAtMs}:${notifIdText}:${mac}`;
}

/** M7/M3 trust boundary for the existing external notification Want contract. */
export class AppShellIntentAdapter {
  private deliveredNotificationKeys: string[] = [];

  toFeatureAction(want: Want, filesDir: string = ''): AppShellFeatureAction {
    const openTaildropInbox: boolean = want.parameters?.taildropOpenInbox === true;
    const action: string | undefined = want.parameters?.taildropNotificationAction as string | undefined;
    const fileName: string | undefined = want.parameters?.taildropNotificationFileName as string | undefined;
    const size: number | undefined = want.parameters?.taildropNotificationFileSize as number | undefined;
    const suppliedReceivedAtMs: number | undefined =
      want.parameters?.taildropNotificationReceivedAtMs as number | undefined;
    const suppliedEventId: string | undefined = want.parameters?.taildropNotificationEventId as string | undefined;
    if (!this.isValidNotificationAction(
      action, fileName, size, suppliedReceivedAtMs, suppliedEventId, filesDir)) {
      const rejected: AppShellFeatureAction = {
        openTaildropInbox: action === undefined ? openTaildropInbox : false,
        taildropNotificationAction: ''
      };
      return rejected;
    }
    const validAction: string = action as string;
    const validFileName: string = fileName as string;
    const validSize: number = size as number;
    const eventId: string = suppliedEventId ?? `legacy:${validFileName}:${validSize}`;
    const key: string = `${eventId}:${validAction}`;
    if (this.deliveredNotificationKeys.includes(key)) {
      const duplicate: AppShellFeatureAction = {
        openTaildropInbox: openTaildropInbox,
        taildropNotificationAction: ''
      };
      return duplicate;
    }
    this.deliveredNotificationKeys.push(key);
    if (this.deliveredNotificationKeys.length > 64) {
      this.deliveredNotificationKeys.shift();
    }
    const payload: SerializedNotificationActionPayload = {
      action: validAction,
      fileName: validFileName,
      size: validSize,
      receivedAtMs: suppliedReceivedAtMs ?? -1,
      eventId: eventId,
      atMs: Date.now()
    };
    const accepted: AppShellFeatureAction = {
      openTaildropInbox: openTaildropInbox,
      taildropNotificationAction: JSON.stringify(payload)
    };
    return accepted;
  }

  private isValidNotificationAction(action: string | undefined, fileName: string | undefined,
    size: number | undefined, receivedAtMs: number | undefined, eventId: string | undefined,
    filesDir: string): boolean {
    if (action !== 'open' && action !== 'save' && action !== 'later') {
      return false;
    }
    if (typeof fileName !== 'string' || fileName.length === 0 || fileName.length > 255 ||
      fileName === '.' || fileName === '..' || fileName.includes('/') || fileName.includes('\\') ||
      hasUnsafeControlOrBidiChars(fileName)) {
      return false;
    }
    if (typeof size !== 'number' || !Number.isSafeInteger(size) || size < 0) {
      return false;
    }
    if (action === 'save') {
      if (typeof receivedAtMs !== 'number' || !Number.isSafeInteger(receivedAtMs) || receivedAtMs <= 0 ||
        typeof eventId !== 'string' || eventId.length === 0 || eventId.length > MAX_EVENT_ID_LENGTH) {
        return false;
      }
      const signedMatch: RegExpExecArray | null =
        /^([1-9][0-9]*):([0-9]+):([0-9a-f]{64})$/.exec(eventId);
      if (signedMatch === null || signedMatch[1] !== String(receivedAtMs)) {
        return false;
      }
      const secretHex: string = readExistingTaildropNotificationSecret(filesDir);
      if (secretHex.length !== SECRET_HEX_LENGTH) {
        return false;
      }
      const expectedMac: string = computeTaildropNotificationHmac(
        secretHex, 'save', fileName, size, receivedAtMs, signedMatch[2]);
      return constantTimeHexEquals(signedMatch[3], expectedMac);
    }

    // Navigation-only 'open' / 'later' actions preserve compatibility with legacy diagnostic Wants.
    if (eventId === undefined && receivedAtMs === undefined) {
      return true;
    }
    if (typeof receivedAtMs !== 'number' || !Number.isSafeInteger(receivedAtMs) || receivedAtMs <= 0 ||
      typeof eventId !== 'string' || eventId.length === 0 || eventId.length > MAX_EVENT_ID_LENGTH) {
      return false;
    }
    const legacyMatch: RegExpExecArray | null = /^([1-9][0-9]*):([0-9]+)$/.exec(eventId);
    if (legacyMatch !== null) {
      return legacyMatch[1] === String(receivedAtMs);
    }
    const signedNavMatch: RegExpExecArray | null =
      /^([1-9][0-9]*):([0-9]+):([0-9a-f]{64})$/.exec(eventId);
    if (signedNavMatch === null || signedNavMatch[1] !== String(receivedAtMs)) {
      return false;
    }
    if (typeof filesDir === 'string' && filesDir.trim().length > 0) {
      const secretHex: string = readExistingTaildropNotificationSecret(filesDir);
      if (secretHex.length !== SECRET_HEX_LENGTH) {
        return false;
      }
      const expectedMac: string = computeTaildropNotificationHmac(
        secretHex, action, fileName, size, receivedAtMs, signedNavMatch[2]);
      return constantTimeHexEquals(signedNavMatch[3], expectedMac);
    }
    return true;
  }
}
