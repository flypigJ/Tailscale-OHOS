import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const REPO_ROOT = new URL('../', import.meta.url);

function readRepoText(relPath) {
  return readFileSync(new URL(relPath, REPO_ROOT), 'utf8').replace(/\r\n/g, '\n');
}

function readResourceEntries(relPath, rootKey) {
  const parsed = JSON.parse(readRepoText(relPath));
  assert.ok(Array.isArray(parsed[rootKey]), `${relPath} must contain a "${rootKey}" array`);
  const map = new Map();
  const duplicates = [];
  for (const item of parsed[rootKey]) {
    assert.equal(typeof item?.name, 'string', `${relPath} entry missing string "name"`);
    assert.equal(typeof item?.value, 'string', `${relPath} entry "${item.name}" missing string "value"`);
    if (map.has(item.name)) {
      duplicates.push(item.name);
    }
    map.set(item.name, item.value);
  }
  assert.deepEqual(duplicates, [], `${relPath} has duplicate keys: ${duplicates.join(', ')}`);
  return map;
}

function extractPlaceholders(text) {
  const matches = [];
  const pattern = /%(?:(\d+)\$)?([sd%])/g;
  let match;
  let sequentialIndex = 0;
  while ((match = pattern.exec(text)) !== null) {
    if (match[2] === '%') {
      continue;
    }
    sequentialIndex += 1;
    const index = match[1] ? Number(match[1]) : sequentialIndex;
    matches.push(`${index}:${match[2]}`);
  }
  return matches.sort();
}

function stripCommentsPreservingLines(source) {
  let out = '';
  let i = 0;
  let quote = '';
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];
    if (quote) {
      out += ch;
      if (ch === '\\' && i + 1 < source.length) {
        out += next;
        i += 2;
        continue;
      }
      if (ch === quote) {
        quote = '';
      }
      i += 1;
      continue;
    }
    if (ch === '\'' || ch === '"' || ch === '`') {
      quote = ch;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === '/' && next === '/') {
      while (i < source.length && source[i] !== '\n') {
        i += 1;
      }
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) {
        if (source[i] === '\n') {
          out += '\n';
        }
        i += 1;
      }
      i += 2;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

function containsCjkOrEscapedCjk(line) {
  if (/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/u.test(line)) {
    return true;
  }
  const unicodeEscape = /\\u([0-9a-fA-F]{4})/g;
  let match;
  while ((match = unicodeEscape.exec(line)) !== null) {
    const code = Number.parseInt(match[1], 16);
    if ((code >= 0x3400 && code <= 0x9fff) || (code >= 0xf900 && code <= 0xfaff)) {
      return true;
    }
  }
  return false;
}

// TaildriveBrowser.specialFolderKind matches remote OS (Windows/macOS/Linux) shared directory
// names to assign folder icons; these are remote filesystem identifiers, NOT UI copy.
const INTENTIONAL_REMOTE_OS_FOLDER_CASE_LINE =
  /^\s*case '(?:桌面|下载|文档|文稿|图片|照片|音乐|视频|影片)':\s*$/;

test('base and zh_CN string.json have 100% identical keys, non-empty values, and matching %s/%d placeholders', () => {
  const baseStrings = readResourceEntries('entry/src/main/resources/base/element/string.json', 'string');
  const zhStrings = readResourceEntries('entry/src/main/resources/zh_CN/element/string.json', 'string');

  const onlyInBase = [...baseStrings.keys()].filter(key => !zhStrings.has(key));
  const onlyInZh = [...zhStrings.keys()].filter(key => !baseStrings.has(key));
  assert.deepEqual(onlyInBase, [], `Keys present only in base/element/string.json: ${onlyInBase.join(', ')}`);
  assert.deepEqual(onlyInZh, [], `Keys present only in zh_CN/element/string.json: ${onlyInZh.join(', ')}`);

  const emptyEntries = [];
  const placeholderMismatches = [];
  for (const [key, baseVal] of baseStrings.entries()) {
    const zhVal = zhStrings.get(key);
    if (baseVal.trim().length === 0) {
      emptyEntries.push(`base:${key}`);
    }
    if (zhVal.trim().length === 0) {
      emptyEntries.push(`zh_CN:${key}`);
    }
    const basePlaceholders = extractPlaceholders(baseVal);
    const zhPlaceholders = extractPlaceholders(zhVal);
    if (basePlaceholders.join(',') !== zhPlaceholders.join(',')) {
      placeholderMismatches.push(
        `${key} (base=[${basePlaceholders.join(', ')}] vs zh_CN=[${zhPlaceholders.join(', ')}])`
      );
    }
  }
  assert.deepEqual(emptyEntries, [], `Empty string resource values: ${emptyEntries.join(', ')}`);
  assert.deepEqual(placeholderMismatches, [], `Placeholder mismatches: ${placeholderMismatches.join('; ')}`);

  const requiredM62Keys = [
    'exit_node_status_none',
    'exit_node_selected',
    'exit_node_list_unavailable',
    'diagnostics_unlock_countdown_toast',
    'connection_duration_just_now',
    'connection_duration_hours_minutes',
    'connection_duration_minutes_seconds',
    'connection_duration_seconds',
    'stream_derp_confirm_title',
    'stream_moonlight_required_title',
    'diagnostic_media_self_test_passed',
    'update_changelog_timeline_code',
    'update_changelog_detail_code'
  ];
  for (const key of requiredM62Keys) {
    assert.ok(baseStrings.has(key) && zhStrings.has(key), `Missing required M6.2 string key: ${key}`);
  }
});

test('base and dark color.json have 100% identical keys and valid #RRGGBB/#AARRGGBB hex values', () => {
  const baseColors = readResourceEntries('entry/src/main/resources/base/element/color.json', 'color');
  const darkColors = readResourceEntries('entry/src/main/resources/dark/element/color.json', 'color');

  const onlyInBase = [...baseColors.keys()].filter(key => !darkColors.has(key));
  const onlyInDark = [...darkColors.keys()].filter(key => !baseColors.has(key));
  assert.deepEqual(onlyInBase, [], `Keys present only in base/element/color.json: ${onlyInBase.join(', ')}`);
  assert.deepEqual(onlyInDark, [], `Keys present only in dark/element/color.json: ${onlyInDark.join(', ')}`);

  const hexPattern = /^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/;
  const invalidValues = [];
  for (const [key, baseVal] of baseColors.entries()) {
    const darkVal = darkColors.get(key);
    if (!hexPattern.test(baseVal)) {
      invalidValues.push(`base:${key}=${baseVal}`);
    }
    if (!hexPattern.test(darkVal)) {
      invalidValues.push(`dark:${key}=${darkVal}`);
    }
  }
  assert.deepEqual(invalidValues, [], `Invalid hex color values: ${invalidValues.join(', ')}`);

  const requiredM62ColorKeys = [
    'pip_traffic_download',
    'pip_traffic_upload',
    'pip_traffic_baseline',
    'pip_traffic_surface',
    'preview_accent_teal',
    'preview_accent_amber',
    'shadow_card_soft',
    'shadow_elevated_soft',
    'shadow_floating_capsule',
    'scrim_modal_overlay',
    'immersive_tint_transfer',
    'immersive_tint_transition',
    'immersive_tint_connected',
    'immersive_tint_idle'
  ];
  for (const key of requiredM62ColorKeys) {
    assert.ok(baseColors.has(key) && darkColors.has(key), `Missing required M6.2 color key: ${key}`);
  }
});

test('components/*.ets contain zero unauthorized hardcoded CJK (literal or \\uXXXX) and zero hardcoded hex colors', () => {
  const componentsDir = new URL('entry/src/main/ets/components/', REPO_ROOT);
  const files = readdirSync(componentsDir).filter(name => name.endsWith('.ets')).sort();
  assert.ok(files.length > 0, 'Expected component .ets files');

  const cjkViolations = [];
  const hexViolations = [];
  const hexExemptFiles = new Set(['UiTokens.ets', 'LightAppearance.ets']);
  const hexLiteralPattern = /#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b/g;

  for (const file of files) {
    const raw = readRepoText(`entry/src/main/ets/components/${file}`);
    const code = stripCommentsPreservingLines(raw);
    const lines = code.split('\n');
    for (let idx = 0; idx < lines.length; idx++) {
      const line = lines[idx];
      if (containsCjkOrEscapedCjk(line)) {
        const allowedRemoteFolderMatcher =
          file === 'TaildriveBrowser.ets' && INTENTIONAL_REMOTE_OS_FOLDER_CASE_LINE.test(line);
        if (!allowedRemoteFolderMatcher) {
          cjkViolations.push(`${file}:${idx + 1}: ${line.trim()}`);
        }
      }
      if (!hexExemptFiles.has(file)) {
        const matches = line.match(hexLiteralPattern);
        if (matches) {
          hexViolations.push(`${file}:${idx + 1}: ${matches.join(', ')}`);
        }
      }
    }
  }

  assert.deepEqual(cjkViolations, [], `Unauthorized hardcoded CJK in components:\n${cjkViolations.join('\n')}`);
  assert.deepEqual(hexViolations, [], `Hardcoded hex literals in components:\n${hexViolations.join('\n')}`);

  const changelog = readRepoText('entry/src/main/ets/components/UpdateChangelogSheet.ets');
  assert.doesNotMatch(changelog, /`[Vv]ersionCode[: ]/);
  assert.match(changelog, /\$r\('app\.string\.update_changelog_timeline_code',\s*entry\.versionCode\)/);
  assert.match(changelog, /\$r\('app\.string\.update_changelog_detail_code',\s*entry\.versionCode\)/);

  const baseStrings = readResourceEntries('entry/src/main/resources/base/element/string.json', 'string');
  const baseColors = readResourceEntries('entry/src/main/resources/base/element/color.json', 'color');
  const missingResourceRefs = [];
  const resourceRefPattern = /\$r\(\s*['"]app\.(string|color)\.([A-Za-z0-9_]+)['"]/g;
  for (const file of files) {
    const code = stripCommentsPreservingLines(readRepoText(`entry/src/main/ets/components/${file}`));
    let match;
    while ((match = resourceRefPattern.exec(code)) !== null) {
      const kind = match[1];
      const name = match[2];
      const table = kind === 'string' ? baseStrings : baseColors;
      if (!table.has(name)) {
        missingResourceRefs.push(`${file}: app.${kind}.${name}`);
      }
    }
  }
  assert.deepEqual(missingResourceRefs, [], `Missing $r('app.*') resource definitions:\n${missingResourceRefs.join('\n')}`);
});

test('NativeSettingsNavigation removes unreachable home/VIP/storage dead code and binds separate Scrollers', () => {
  const native = readRepoText('entry/src/main/ets/components/NativeSettingsNavigation.ets');
  const removedSymbols = [
    'SettingsHome',
    'ProfileHero',
    'native-settings-vip',
    'StoragePage',
    'StorageSummaryRow',
    'PageMap',
    'IconButton',
    'TopBar',
    'SectionTitle',
    'SettingsRow',
    'TransferSpaceRow',
    'HdsNavDestination',
    'HdsNavDestinationAttribute',
    'HdsNavDestinationTitleMode',
    'pushPage',
    'popPage',
    'storageMegabytes',
    'storageTotalBytes',
    'storageTotalLabel',
    'navPathStack',
    'navigationLockUntilMs',
    'hdrEnabled',
    'floatingTabsEnabled',
    'pageScroller',
    'profileName',
    'storageAppDataBytes',
    'storageReceivedBytes',
    'storageTemporaryBytes',
    'storageClearEnabled',
    'onSelectTransfer',
    'onClearTemporaryStorage'
  ];
  for (const symbol of removedSymbols) {
    assert.equal(native.includes(symbol), false, `NativeSettingsNavigation.ets still contains dead symbol "${symbol}"`);
  }

  assert.match(native, /private backgroundScroller:\s*Scroller\s*=\s*new Scroller\(\);/);
  assert.match(native, /private animationScroller:\s*Scroller\s*=\s*new Scroller\(\);/);
  assert.match(native, /private BackgroundPage\(\):\s*void\s*\{\s*Column\(\)\s*\{\s*Scroll\(this\.backgroundScroller\)/);
  assert.match(native, /private AnimationPage\(\):\s*void\s*\{\s*Column\(\)\s*\{\s*Scroll\(this\.animationScroller\)/);
  assert.match(
    native,
    /\.bindToScrollable\(\[this\.pageName === 'animation'\s*\?\s*this\.animationScroller\s*:\s*this\.backgroundScroller\]\)/
  );

  const bridge = readRepoText('entry/src/main/ets/components/BridgeStatus.ets');
  const callsiteStart = bridge.indexOf('NativeSettingsNavigation({');
  assert.ok(callsiteStart >= 0, 'Expected NativeSettingsNavigation callsite in BridgeStatus.ets');
  const callsiteEnd = bridge.indexOf('})', callsiteStart);
  assert.ok(callsiteEnd > callsiteStart, 'Expected closing }) for NativeSettingsNavigation callsite');
  const callsite = bridge.slice(callsiteStart, callsiteEnd + 2);
  for (const deadProp of [
    'profileName',
    'storageAppDataBytes',
    'storageReceivedBytes',
    'storageTemporaryBytes',
    'storageClearEnabled',
    'onSelectTransfer',
    'onClearTemporaryStorage'
  ]) {
    assert.equal(callsite.includes(deadProp), false, `BridgeStatus callsite still passes removed prop "${deadProp}"`);
  }
});
