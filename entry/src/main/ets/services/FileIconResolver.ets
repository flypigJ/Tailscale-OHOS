import {
  FileIconKey,
  FileIconTone,
  resolveFileIconKey,
  resolveFileIconTone
} from '@tailscale/common';

/**
 * Entry-module ArkUI resource adapter for framework-free @tailscale/common
 * FileIconKey and FileIconTone classifications.
 */
export function resolveFileIconResource(name: string): Resource {
  const key: FileIconKey = resolveFileIconKey(name);
  switch (key) {
    case '7z': return $r('app.media.ic_light_7z');
    case 'amr': return $r('app.media.ic_light_amr');
    case 'ape': return $r('app.media.ic_light_ape');
    case 'app': return $r('app.media.ic_light_app');
    case 'caj': return $r('app.media.ic_light_caj');
    case 'calendar': return $r('app.media.ic_light_calendar');
    case 'chm': return $r('app.media.ic_light_chm');
    case 'connect': return $r('app.media.ic_light_connect');
    case 'download': return $r('app.media.ic_light_download');
    case 'dwg': return $r('app.media.ic_light_dwg');
    case 'dxf': return $r('app.media.ic_light_dxf');
    case 'eddx': return $r('app.media.ic_light_eddx');
    case 'eml': return $r('app.media.ic_light_eml');
    case 'emmx': return $r('app.media.ic_light_emmx');
    case 'excel': return $r('app.media.ic_light_excel');
    case 'exe': return $r('app.media.ic_light_exe');
    case 'flac': return $r('app.media.ic_light_flac');
    case 'gz': return $r('app.media.ic_light_gz');
    case 'hdoc': return $r('app.media.ic_light_hdoc');
    case 'hinote': return $r('app.media.ic_light_hinote');
    case 'htm': return $r('app.media.ic_light_htm');
    case 'html': return $r('app.media.ic_light_html');
    case 'kdh': return $r('app.media.ic_light_kdh');
    case 'log': return $r('app.media.ic_light_log');
    case 'm4a': return $r('app.media.ic_light_m4a');
    case 'mp3': return $r('app.media.ic_light_mp3');
    case 'music': return $r('app.media.ic_light_music');
    case 'nh': return $r('app.media.ic_light_nh');
    case 'other': return $r('app.media.ic_light_other');
    case 'other_app': return $r('app.media.ic_light_other_app');
    case 'pdf': return $r('app.media.ic_light_pdf');
    case 'picture': return $r('app.media.ic_light_picture');
    case 'ppt': return $r('app.media.ic_light_ppt');
    case 'rar': return $r('app.media.ic_light_rar');
    case 'tar': return $r('app.media.ic_light_tar');
    case 'teb': return $r('app.media.ic_light_teb');
    case 'text': return $r('app.media.ic_light_text');
    case 'txt': return $r('app.media.ic_light_txt');
    case 'unknow': return $r('app.media.ic_light_unknow');
    case 'video': return $r('app.media.ic_light_video');
    case 'wav': return $r('app.media.ic_light_wav');
    case 'wma': return $r('app.media.ic_light_wma');
    case 'word': return $r('app.media.ic_light_word');
    case 'xml': return $r('app.media.ic_light_xml');
    case 'zip': return $r('app.media.ic_light_zip');
    case 'zip_1': return $r('app.media.ic_light_zip_1');
  }
}

export function resolveFileIconColorResource(name: string): ResourceColor {
  const tone: FileIconTone = resolveFileIconTone(name);
  switch (tone) {
    case 'red': return $r('app.color.transfer_file_icon_red');
    case 'yellow': return $r('app.color.transfer_file_icon_yellow');
    case 'neutral': return $r('app.color.transfer_file_icon_neutral');
    case 'blue': return $r('app.color.transfer_file_icon_blue');
  }
}
