/**
 * Framework-free file extension, media/text content classification, and icon-key catalog.
 * Authoritative single source of truth shared across Taildrop notifications, Taildrop UI,
 * Taildrive previews, and Taildrive browser rows/cards.
 */

export type FileContentKind = 'image' | 'video' | 'text' | 'file';

export type FileIconTone = 'red' | 'yellow' | 'neutral' | 'blue';

export type FileIconKey =
  '7z' | 'amr' | 'ape' | 'app' | 'caj' | 'calendar' | 'chm' | 'connect' | 'download' |
  'dwg' | 'dxf' | 'eddx' | 'eml' | 'emmx' | 'excel' | 'exe' | 'flac' | 'gz' | 'hdoc' |
  'hinote' | 'htm' | 'html' | 'kdh' | 'log' | 'm4a' | 'mp3' | 'music' | 'nh' |
  'other' | 'other_app' | 'pdf' | 'picture' | 'ppt' | 'rar' | 'tar' | 'teb' | 'text' |
  'txt' | 'unknow' | 'video' | 'wav' | 'wma' | 'word' | 'xml' | 'zip' | 'zip_1';

export const TAILDROP_TEXT_MAX_CLIPBOARD_BYTES: number = 1024 * 1024;
export const TAILDROP_TEXT_CLIPBOARD_MAX_BYTES: number = TAILDROP_TEXT_MAX_CLIPBOARD_BYTES;

export const IMAGE_FILE_EXTENSIONS: string[] = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'dng'
];

export const PREVIEW_IMAGE_FILE_EXTENSIONS: string[] = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'dng', 'svg'
];

// TypeScript source (.ts) is intentionally excluded from video extensions.
export const VIDEO_FILE_EXTENSIONS: string[] = [
  'mp4', 'mov', 'm4v', '3gp', '3g2', 'mkv', 'webm', 'avi'
];

export const TEXT_FILE_EXTENSIONS: string[] = [
  'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'json5', 'jsonl', 'toml',
  'xml', 'yaml', 'yml', 'log', 'ini', 'conf', 'cfg', 'properties', 'env',
  'sql', 'sh', 'ps1', 'bat', 'cmd', 'py', 'js', 'jsx', 'ts', 'tsx', 'ets',
  'css', 'html', 'htm', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cc', 'cpp',
  'h', 'hpp'
];

/** Extracts lowercase extension without leading dot, including hidden dotfiles like '.env' -> 'env'. */
export function extractFileExtension(name: string): string {
  const slashIndex: number = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
  const baseName: string = slashIndex >= 0 ? name.substring(slashIndex + 1) : name;
  if (baseName.length === 0 || baseName === '.' || baseName === '..') {
    return '';
  }
  const dotIndex: number = baseName.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex === baseName.length - 1) {
    return '';
  }
  return baseName.substring(dotIndex + 1).toLowerCase();
}

export function isMediaFileName(name: string): boolean {
  const extension: string = extractFileExtension(name);
  return IMAGE_FILE_EXTENSIONS.includes(extension) || VIDEO_FILE_EXTENSIONS.includes(extension);
}

export function isImageEntry(name: string, contentType?: string): boolean {
  const normalizedType: string = (contentType ?? '').trim().toLowerCase();
  if (normalizedType.startsWith('image/')) {
    return true;
  }
  return PREVIEW_IMAGE_FILE_EXTENSIONS.includes(extractFileExtension(name));
}

export function isVideoEntry(name: string, contentType?: string): boolean {
  const normalizedType: string = (contentType ?? '').trim().toLowerCase();
  if (normalizedType.startsWith('video/')) {
    return true;
  }
  return VIDEO_FILE_EXTENSIONS.includes(extractFileExtension(name));
}

export function classifyFileContentKind(
  name: string,
  sizeBytes?: number,
  maxTextBytes: number = TAILDROP_TEXT_MAX_CLIPBOARD_BYTES
): FileContentKind {
  const extension: string = extractFileExtension(name);
  if (IMAGE_FILE_EXTENSIONS.includes(extension)) {
    return 'image';
  }
  if (VIDEO_FILE_EXTENSIONS.includes(extension)) {
    return 'video';
  }
  const withinTextLimit: boolean = sizeBytes === undefined ||
    (Number.isFinite(sizeBytes) && sizeBytes >= 0 && sizeBytes <= maxTextBytes);
  if (withinTextLimit && TEXT_FILE_EXTENSIONS.includes(extension)) {
    return 'text';
  }
  return 'file';
}

export function resolveFileIconKey(name: string): FileIconKey {
  const extension: string = extractFileExtension(name);
  switch (extension) {
    case '7z': return '7z';
    case 'amr': return 'amr';
    case 'ape': return 'ape';
    case 'app': return 'app';
    case 'caj': return 'caj';
    case 'ics':
    case 'ical':
    case 'calendar': return 'calendar';
    case 'chm': return 'chm';
    case 'connect':
    case 'connection': return 'connect';
    case 'crdownload':
    case 'download':
    case 'part':
    case 'partial': return 'download';
    case 'dwg': return 'dwg';
    case 'dxf': return 'dxf';
    case 'eddx': return 'eddx';
    case 'eml':
    case 'emlx':
    case 'msg': return 'eml';
    case 'emmx': return 'emmx';
    case 'xls':
    case 'xlsx':
    case 'xlsm':
    case 'xlsb':
    case 'csv':
    case 'et':
    case 'ett':
    case 'ods': return 'excel';
    case 'exe':
    case 'msi':
    case 'com': return 'exe';
    case 'flac': return 'flac';
    case 'gz':
    case 'gzip': return 'gz';
    case 'hdoc': return 'hdoc';
    case 'hinote': return 'hinote';
    case 'htm': return 'htm';
    case 'html':
    case 'xhtml':
    case 'mht':
    case 'mhtml': return 'html';
    case 'kdh': return 'kdh';
    case 'log': return 'log';
    case 'm4a': return 'm4a';
    case 'mp3': return 'mp3';
    case 'aac':
    case 'midi':
    case 'mid':
    case 'ogg':
    case 'opus': return 'music';
    case 'nh': return 'nh';
    case 'pdf': return 'pdf';
    case 'ppt':
    case 'pptx':
    case 'pptm':
    case 'pps':
    case 'ppsx':
    case 'dps':
    case 'dpt':
    case 'odp': return 'ppt';
    case 'rar': return 'rar';
    case 'tar': return 'tar';
    case 'teb': return 'teb';
    case 'txt': return 'txt';
    case 'wav': return 'wav';
    case 'wma': return 'wma';
    case 'doc':
    case 'docx':
    case 'docm':
    case 'dot':
    case 'dotx':
    case 'wps':
    case 'wpt':
    case 'odt':
    case 'rtf': return 'word';
    case 'xml':
    case 'xsl':
    case 'xslt': return 'xml';
    case 'zip': return 'zip';
    case 'bz2':
    case 'xz':
    case 'zst':
    case 'lz':
    case 'lz4':
    case 'cab':
    case 'iso':
    case 'dmg': return 'zip_1';
    case 'hap':
    case 'hsp':
    case 'har':
    case 'apk':
    case 'aab':
    case 'ipa': return 'other_app';
  }
  if (PREVIEW_IMAGE_FILE_EXTENSIONS.includes(extension)) {
    return 'picture';
  }
  if (VIDEO_FILE_EXTENSIONS.includes(extension)) {
    return 'video';
  }
  if (TEXT_FILE_EXTENSIONS.includes(extension)) {
    return 'text';
  }
  return extension.length === 0 ? 'unknow' : 'other';
}

export function resolveFileIconTone(name: string): FileIconTone {
  const extension: string = extractFileExtension(name);
  if (extension === 'pdf' ||
    ['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'amr', 'ape', 'wma'].includes(extension) ||
    PREVIEW_IMAGE_FILE_EXTENSIONS.includes(extension) ||
    VIDEO_FILE_EXTENSIONS.includes(extension)) {
    return 'red';
  }
  if (['zip', 'rar', '7z', 'tar', 'gz', 'gzip', 'bz2', 'xz', 'zst', 'lz', 'lz4', 'cab', 'iso', 'dmg']
    .includes(extension)) {
    return 'yellow';
  }
  if (['hap', 'hsp', 'har', 'app', 'apk', 'aab', 'ipa'].includes(extension)) {
    return 'neutral';
  }
  return 'blue';
}
